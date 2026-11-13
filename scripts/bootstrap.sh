#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"

billing_account=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --billing-account) billing_account=${2:?--billing-account needs a value}; shift 2 ;;
    --billing-account=*) billing_account=${1#*=}; shift ;;
    *) die "usage: $0 [--billing-account ID]" ;;
  esac
done

need gcloud jq openssl
config_check
account=$(gcloud config get-value account 2>/dev/null)
[[ -n $account ]] || die "no active gcloud account, run gcloud auth login"

report() { printf '%-8s %s\n' "$1" "$2"; }

PROJECT=$(cfg '.project.id // ""')
REGION=$(cfg '.project.region')
PREFIX=$(cfg '.project.name_prefix')
if [[ -z $PROJECT ]]; then
  PROJECT="$PREFIX-$(openssl rand -hex 3)"
  tmp=$(mktemp "$CONFIG.XXXXXX")
  jq --arg id "$PROJECT" '.project.id = $id' < "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  report written "project.id = $PROJECT in $CONFIG"
fi

if gcloud projects describe "$PROJECT" --format='value(projectId)' >/dev/null 2>&1; then
  report exists "project $PROJECT"
else
  gcloud projects create "$PROJECT" >/dev/null
  report created "project $PROJECT"
fi

if [[ $(gcloud billing projects describe "$PROJECT" --format='value(billingEnabled)') == True ]]; then
  report exists "billing for $PROJECT"
else
  if [[ -z $billing_account ]]; then
    mapfile -t accounts < <(gcloud billing accounts list --filter=open=true --format='value(name)' | sed 's#^billingAccounts/##')
    [[ ${#accounts[@]} -eq 1 ]] || die "pass --billing-account ID; open billing accounts: ${accounts[*]:-none}"
    billing_account=${accounts[0]}
  fi
  gcloud billing projects link "$PROJECT" --billing-account="$billing_account" >/dev/null
  report created "billing $billing_account for $PROJECT"
fi

gcloud services enable compute.googleapis.com iap.googleapis.com storage.googleapis.com \
  secretmanager.googleapis.com iam.googleapis.com iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com serviceusage.googleapis.com sqladmin.googleapis.com \
  servicenetworking.googleapis.com logging.googleapis.com monitoring.googleapis.com --project "$PROJECT" >/dev/null
report enabled "APIs"

if gcloud compute networks describe default --project "$PROJECT" >/dev/null 2>&1; then
  if [[ -z $(gcloud compute instances list --project "$PROJECT" --format='value(name)') ]]; then
    mapfile -t rules < <(gcloud compute firewall-rules list --project "$PROJECT" --filter=network:default --format='value(name)')
    if [[ ${#rules[@]} -gt 0 ]]; then
      gcloud compute firewall-rules delete "${rules[@]}" --project "$PROJECT" --quiet >/dev/null
    fi
    gcloud compute networks delete default --project "$PROJECT" --quiet >/dev/null
    report deleted "network default"
  else
    report kept "network default (project has VMs)"
  fi
else
  report exists "no network default"
fi

BUCKET=gs://$PROJECT-tfstate
if gcloud storage buckets describe "$BUCKET" >/dev/null 2>&1; then
  report exists "bucket $BUCKET"
else
  gcloud storage buckets create "$BUCKET" --project "$PROJECT" --location "$REGION" \
    --uniform-bucket-level-access --public-access-prevention >/dev/null
  lifecycle=$(mktemp)
  echo '{"rule":[{"action":{"type":"Delete"},"condition":{"numNewerVersions":10,"isLive":false}}]}' > "$lifecycle"
  gcloud storage buckets update "$BUCKET" --versioning --lifecycle-file="$lifecycle" >/dev/null
  rm -f "$lifecycle"
  report created "bucket $BUCKET"
fi

SA=terraform@$PROJECT.iam.gserviceaccount.com
if gcloud iam service-accounts describe "$SA" --project "$PROJECT" >/dev/null 2>&1; then
  report exists "service account $SA"
else
  gcloud iam service-accounts create terraform --display-name="Terraform" --project "$PROJECT" >/dev/null
  report created "service account $SA"
fi

retry() {
  local n
  for n in 1 2 3 4 5; do
    "$@" >/dev/null 2>&1 && return 0
    echo "waiting for IAM to see $SA ($n/5)" >&2
    sleep 10
  done
  "$@" >/dev/null
}

retry gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA" \
  --role=roles/compute.admin --condition=None --quiet
retry gcloud storage buckets add-iam-policy-binding "$BUCKET" --member="serviceAccount:$SA" \
  --role=roles/storage.objectAdmin
for role in roles/cloudsql.admin roles/servicenetworking.networksAdmin roles/iam.serviceAccountAdmin roles/monitoring.editor roles/logging.configWriter; do
  retry gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA" \
    --role="$role" --condition=None --quiet
done
condition=$(mktemp)
cat > "$condition" <<'EOF'
title: iss-app-grants-only
expression: api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly(['roles/cloudsql.client', 'roles/cloudsql.instanceUser', 'roles/logging.logWriter', 'roles/monitoring.metricWriter', 'roles/secretmanager.secretAccessor'])
EOF
retry gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA" \
  --role=roles/resourcemanager.projectIamAdmin --condition-from-file="$condition" --quiet
for old in "iss-cloudsql-grants-only|'roles/cloudsql.client', 'roles/cloudsql.instanceUser'" \
  "iss-app-grants-only|'roles/cloudsql.client', 'roles/cloudsql.instanceUser', 'roles/logging.logWriter', 'roles/monitoring.metricWriter'"; do
  printf "title: %s\nexpression: api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly([%s])\n" \
    "${old%%|*}" "${old#*|}" > "$condition"
  gcloud projects remove-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA" \
    --role=roles/resourcemanager.projectIamAdmin --condition-from-file="$condition" --quiet >/dev/null 2>&1 || true
done
rm -f "$condition"

member="user:$account"
[[ $account == *.gserviceaccount.com ]] && member="serviceAccount:$account"
gcloud iam service-accounts remove-iam-policy-binding "$SA" --member="$member" \
  --role=roles/iam.serviceAccountTokenCreator --project "$PROJECT" >/dev/null 2>&1 || true
report granted "compute, Cloud SQL, networking, service account admin, app grants and state bucket to $SA"

number=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
compute_sa=$number-compute@developer.gserviceaccount.com
found=false
for n in 1 2 3 4 5 6; do
  if disabled=$(gcloud iam service-accounts describe "$compute_sa" --project "$PROJECT" --format='value(disabled)' 2>/dev/null); then
    found=true
    break
  fi
  echo "waiting for $compute_sa ($n/6)" >&2
  sleep 10
done
if [[ $found != true ]]; then
  report skipped "default compute service account (not created yet; run ./scripts/bootstrap.sh again later)"
else
  if [[ -n $(gcloud projects get-iam-policy "$PROJECT" --flatten='bindings[].members' \
    --filter="bindings.role=roles/editor AND bindings.members=serviceAccount:$compute_sa" \
    --format='value(bindings.role)') ]]; then
    gcloud projects remove-iam-policy-binding "$PROJECT" --member="serviceAccount:$compute_sa" \
      --role=roles/editor --condition=None --quiet >/dev/null
    report removed "roles/editor from $compute_sa"
  fi
  if [[ $disabled == True ]]; then
    report exists "$compute_sa disabled"
  else
    gcloud iam service-accounts disable "$compute_sa" --project "$PROJECT" --quiet >/dev/null
    report disabled "$compute_sa"
  fi
fi

key=$(sa_key_path) || exit 1
if [[ -f $key ]]; then
  report exists "key $key"
else
  mkdir -p "$(dirname "$key")"
  if ! err=$( (umask 077; gcloud iam service-accounts keys create "$key" --iam-account "$SA" --project "$PROJECT") 2>&1 >/dev/null); then
    rm -f "$key"
    [[ $err == *disableServiceAccountKeyCreation* ]] && die "key creation is blocked by org policy iam.disableServiceAccountKeyCreation"
    die "cannot create a key for $SA: $err"
  fi
  report created "key $key"
fi

random_password() { openssl rand -hex 16; }

for name in "${SECRETS[@]}"; do
  if gcloud secrets describe "$name" --project "$PROJECT" >/dev/null 2>&1; then
    report exists "secret $name"
  else
    gcloud secrets create "$name" --replication-policy=automatic --project "$PROJECT" >/dev/null
    report created "secret $name"
  fi
done

for name in "${SECRETS[@]}"; do
  for role in roles/secretmanager.secretAccessor roles/secretmanager.viewer; do
    retry gcloud secrets add-iam-policy-binding "$name" --member="serviceAccount:$SA" --role="$role" --project "$PROJECT"
  done
done
for role in roles/secretmanager.secretVersionAdder roles/secretmanager.secretVersionManager; do
  retry gcloud secrets add-iam-policy-binding LETSENCRYPT_STATE --member="serviceAccount:$SA" --role="$role" --project "$PROJECT"
done
report granted "secret access to $SA"

for name in "${GENERATED_SECRETS[@]}"; do
  secret_has_value "$name" && continue
  case $name in
    *_PASSWORD) value=$(random_password) ;;
    *) value="u_$(openssl rand -hex 3)" ;;
  esac
  printf '%s' "$value" | gcloud secrets versions add "$name" --data-file=- --project "$PROJECT" >/dev/null
  report set "secret $name (generated)"
done

missing=()
for name in CF_TUNNEL_TOKEN CLOUDFLARE_API_TOKEN; do
  secret_has_value "$name" || missing+=("$name")
done

echo
echo "project: $PROJECT"
for name in "${missing[@]}"; do
  echo "set $name: ./scripts/secret-set.sh $name"
done
echo "next: ./scripts/tf.sh init && ./scripts/tf.sh apply"
