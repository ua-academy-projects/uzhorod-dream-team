#!/bin/bash
# Day-zero bootstrap: project, billing, APIs, Terraform state bucket, service account and its JSON key. Safe to re-run.
# Usage: [BILLING_ACCOUNT=<id>] ./bootstrap.sh
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG=$DIR/../../terraform_resources_configuration/config.json
BACKEND_FILE=$DIR/../terraform/backend.hcl

die() {
  echo "ERROR: $*" >&2
  exit 1
}

config_value() {
  python3 -I -c '
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2:]:
    value = value.get(key, "")
print("\n".join(value) if isinstance(value, list) else value)' "$CONFIG" "$@"
}

save_project_id() {
  python3 -I -c '
import json, os, sys
config = json.load(open(sys.argv[1]))
config["project_id"] = sys.argv[2]
with open(sys.argv[1] + ".tmp", "w") as f:
    json.dump(config, f, indent=4, ensure_ascii=False)
    f.write("\n")
os.replace(sys.argv[1] + ".tmp", sys.argv[1])' "$CONFIG" "$1"
}

# New IAM objects show up with a delay.
retry() {
  for attempt in $(seq 1 12); do
    if "$@"; then
      return 0
    fi
    echo "    attempt $attempt failed, retrying in 5 s"
    sleep 5
  done
  return 1
}

default_sa_has_editor() {
  [ -n "$(gcloud projects get-iam-policy "$PROJECT_ID" --flatten='bindings[].members' \
    --filter="bindings.role=roles/editor AND bindings.members=serviceAccount:$DEFAULT_SA" --format='value(bindings.role)')" ]
}

remove_default_sa_editor() {
  local project_number
  project_number=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
  DEFAULT_SA=$project_number-compute@developer.gserviceaccount.com

  echo "==> Waiting for the default Compute Engine account $DEFAULT_SA"
  retry gcloud iam service-accounts describe "$DEFAULT_SA" --project="$PROJECT_ID" >/dev/null \
    || die "$DEFAULT_SA did not appear."
  if [ "$CREATED" = 1 ]; then
    echo "==> Waiting for Google to grant roles/editor to $DEFAULT_SA"
    retry default_sa_has_editor || true
  fi

  if ! default_sa_has_editor; then
    echo "skip: $DEFAULT_SA has no roles/editor"
    return
  fi
  echo "==> Removing roles/editor from $DEFAULT_SA"
  gcloud projects remove-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$DEFAULT_SA" --role=roles/editor \
    --condition=None --quiet >/dev/null
  if default_sa_has_editor; then
    die "$DEFAULT_SA still has roles/editor."
  fi
}

delete_default_network() {
  local vms rules rule
  if ! gcloud compute networks describe default --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "skip: no network 'default'"
    return
  fi
  vms=$(gcloud compute instances list --project="$PROJECT_ID" --filter='networkInterfaces.network~/default$' --format='value(name)')
  if [ -n "$vms" ]; then
    echo "WARNING: network 'default' is used by: $vms. Not deleting it."
    return
  fi

  echo "==> Deleting network 'default' and its firewall rules"
  mapfile -t rules < <(gcloud compute firewall-rules list --project="$PROJECT_ID" --filter='network~/default$' --format='value(name)')
  for rule in "${rules[@]}"; do
    gcloud compute firewall-rules delete "$rule" --project="$PROJECT_ID" --quiet
  done
  gcloud compute networks delete default --project="$PROJECT_ID" --quiet
}

# 1. Config
echo "==> gcloud account: $(gcloud config get-value account)"

PROJECT_ID=$(config_value project_id)
PROJECT_ID_PREFIX=$(config_value bootstrap project_id_prefix)
PROJECT_NAME=$(config_value bootstrap project_name)
REGION=$(config_value region)
SA_NAME=$(config_value bootstrap terraform_service_account)
STATE_PREFIX=$(config_value bootstrap state_prefix)
mapfile -t APIS < <(config_value bootstrap apis)
mapfile -t ROLES < <(config_value bootstrap terraform_roles)

[ -n "${APIS[0]:-}" ] || die "bootstrap.apis in config.json is empty."
[[ "$SA_NAME" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] \
  || die "bootstrap.terraform_service_account '$SA_NAME' is not a valid account name."
[[ "$STATE_PREFIX" =~ ^[A-Za-z0-9/_.-]+$ ]] \
  || die "bootstrap.state_prefix '$STATE_PREFIX' may only have letters, digits and / _ . -"

# 2. Project

if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$PROJECT_ID_PREFIX-$(openssl rand -hex 3)
  [[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] \
    || die "'$PROJECT_ID' is not a valid project id, check bootstrap.project_id_prefix."
  # Saved before create, so an interrupted run reuses the id.
  echo "==> project_id is empty: new project id $PROJECT_ID, saved to config.json"
  save_project_id "$PROJECT_ID"
fi

CREATED=0
PROJECT_STATE=$(gcloud projects describe "$PROJECT_ID" --format='value(lifecycleState)' 2>/dev/null) || true
if [ "$PROJECT_STATE" = ACTIVE ]; then
  echo "skip: project $PROJECT_ID already exists"
elif [ "$PROJECT_STATE" = DELETE_REQUESTED ]; then
  die "project $PROJECT_ID is DELETE_REQUESTED (deleted, kept for 30 days).
Restore it with 'gcloud projects undelete $PROJECT_ID' or clear project_id in config.json."
else
  echo "==> Creating project $PROJECT_ID"
  # Steps 5 and 6 run only in projects with this label.
  gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME" --labels=created-by=bootstrap \
    || die "could not create project $PROJECT_ID, the id may be taken.
Clear project_id in config.json to get a new id and run again."
  CREATED=1
fi

# 3. Billing

if [ "$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)')" = True ]; then
  echo "skip: billing is already enabled for $PROJECT_ID"
else
  if [ -z "${BILLING_ACCOUNT:-}" ]; then
    mapfile -t OPEN_ACCOUNTS < <(gcloud billing accounts list --filter=open=true --format='value(name.basename())')
    [ "${#OPEN_ACCOUNTS[@]}" = 1 ] || die "found ${#OPEN_ACCOUNTS[@]} open billing accounts, expected exactly one.
Run again with: BILLING_ACCOUNT=<id> ./bootstrap.sh"
    BILLING_ACCOUNT=${OPEN_ACCOUNTS[0]}
  fi
  echo "==> Linking $PROJECT_ID to billing account ...${BILLING_ACCOUNT: -4}"
  gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
fi

# 4. APIs

echo "==> Enabling APIs in $PROJECT_ID"
gcloud services enable "${APIS[@]}" --project="$PROJECT_ID"

# 5-6. Default compute account and network, only in our own projects

if [ "$(gcloud projects describe "$PROJECT_ID" --format='value(labels.created-by)')" = bootstrap ]; then
  remove_default_sa_editor
  delete_default_network
else
  echo "skip: $PROJECT_ID was not created by bootstrap.sh, its default account and network are left as they are"
fi

# 7. State bucket

BUCKET=$PROJECT_ID-tfstate
if gcloud storage buckets describe "gs://$BUCKET" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "skip: state bucket gs://$BUCKET already exists"
else
  echo "==> Creating state bucket gs://$BUCKET"
  gcloud storage buckets create "gs://$BUCKET" --project="$PROJECT_ID" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention
fi
echo "==> Versioning on, public access off for gs://$BUCKET"
gcloud storage buckets update "gs://$BUCKET" --versioning --uniform-bucket-level-access --public-access-prevention

# 8. Terraform service account

SA_EMAIL=$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "skip: service account $SA_EMAIL already exists"
else
  echo "==> Creating service account $SA_EMAIL"
  gcloud iam service-accounts create "$SA_NAME" --project="$PROJECT_ID" --display-name="Terraform"
fi

for role in "${ROLES[@]}"; do
  echo "==> Granting $role to $SA_EMAIL"
  retry gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA_EMAIL" --role="$role" \
    --condition=None --quiet >/dev/null \
    || die "could not grant $role to $SA_EMAIL."
done

echo "==> Granting $SA_EMAIL access to the state in gs://$BUCKET only"
retry gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member="serviceAccount:$SA_EMAIL" \
  --role=roles/storage.objectAdmin --condition=None --quiet >/dev/null \
  || die "could not grant access to gs://$BUCKET."

# 9. JSON key
KEY_FILE=${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/$PROJECT_ID-terraform.json
if [ -f "$KEY_FILE" ]; then
  KEY_ID=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("private_key_id", ""))' "$KEY_FILE" 2>/dev/null) \
    || KEY_ID=""
  KEYS=$(gcloud iam service-accounts keys list --iam-account="$SA_EMAIL" --project="$PROJECT_ID" --managed-by=user \
    --format='value(name.basename())')
  if [ -n "$KEY_ID" ] && grep -qx "$KEY_ID" <<< "$KEYS"; then
    echo "skip: key $KEY_FILE is still valid"
  else
    echo "==> Key in $KEY_FILE is no longer on $SA_EMAIL, creating a new one"
    rm -f "$KEY_FILE"
  fi
fi
if [ ! -f "$KEY_FILE" ]; then
  echo "==> Creating key $KEY_FILE"
  (umask 077 && retry gcloud iam service-accounts keys create "$KEY_FILE" --iam-account="$SA_EMAIL" --project="$PROJECT_ID") \
    || die "could not create a key for $SA_EMAIL. If it already has 10 keys, delete old ones, see:
  gcloud iam service-accounts keys list --iam-account=$SA_EMAIL --project=$PROJECT_ID"
fi
chmod 600 "$KEY_FILE"
[ "$(stat -c %a "$KEY_FILE")" = 600 ] \
  || die "$KEY_FILE is not 600, the disk ignores permissions (a Windows drive?). Keep the key on the Linux disk."

# 10. backend.hcl

echo "==> Writing $BACKEND_FILE"
cat > "$BACKEND_FILE" <<EOF
bucket = "$BUCKET"
prefix = "$STATE_PREFIX"
EOF

echo
echo "Bootstrap of $PROJECT_ID is done. New IAM grants can take a minute or two to work. Next:"
echo "  export GOOGLE_APPLICATION_CREDENTIALS=$KEY_FILE    # if GOOGLE_APPLICATION_CREDENTIALS is not set, Terraform runs as you"
echo "  cd $(cd "$DIR/../terraform" && pwd)"
echo "  terraform init -reconfigure -backend-config=backend.hcl"
echo "  terraform plan"
