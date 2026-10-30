#!/bin/bash
# Day-zero bootstrap: creates the GCP project, links billing, enables the APIs, creates the
# Terraform state bucket and the Terraform service account. Safe to run again: every step
# checks what is already done.
# Usage: ./bootstrap.sh   (BILLING_ACCOUNT=<id> ./bootstrap.sh when there are several billing accounts)
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG=$DIR/../../terraform_resources_configuration/config.json

# config_value KEY [KEY...] prints the value of config.json at that path, a list one item per line.
config_value() {
  python3 -I -c '
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2:]:
    value = value.get(key, "")
print("\n".join(value) if isinstance(value, list) else value)' "$CONFIG" "$@"
}

# retry CMD... runs CMD up to 12 times, 5 s apart: new IAM objects appear with a delay.
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

PROJECT_ID=$(config_value project_id)
PREFIX=$(config_value bootstrap project_id_prefix)
PROJECT_NAME=$(config_value bootstrap project_name)
mapfile -t APIS < <(config_value bootstrap apis)
if [ -z "${APIS[0]:-}" ]; then
  echo "ERROR: bootstrap.apis in config.json is empty." >&2
  exit 1
fi

ACCOUNT=$(gcloud config get-value account)
echo "==> Checking that gcloud and Application Default Credentials are the same account ($ACCOUNT)"
ADC_TOKEN=$(gcloud auth application-default print-access-token)
ADC_EMAIL=$(printf 'access_token=%s' "$ADC_TOKEN" | curl -s --max-time 10 -d @- https://oauth2.googleapis.com/tokeninfo \
  | python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("email", ""))') || true
unset ADC_TOKEN
if [ "${ADC_EMAIL,,}" != "${ACCOUNT,,}" ]; then
  echo "ERROR: Application Default Credentials belong to '$ADC_EMAIL', gcloud uses '$ACCOUNT'." >&2
  echo "Terraform impersonates through ADC. Run: gcloud auth application-default login (as $ACCOUNT)" >&2
  exit 1
fi

if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$PREFIX-$(openssl rand -hex 3)
  if ! [[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
    echo "ERROR: '$PROJECT_ID' is not a valid project id, check bootstrap.project_id_prefix." >&2
    exit 1
  fi
  echo "==> project_id is empty: new project id $PROJECT_ID, saved to config.json"
  # Written through a temp file, so an interrupted run never leaves config.json half-written.
  python3 -I -c '
import json, os, sys
config = json.load(open(sys.argv[1]))
config["project_id"] = sys.argv[2]
with open(sys.argv[1] + ".tmp", "w") as f:
    json.dump(config, f, indent=4, ensure_ascii=False)
    f.write("\n")
os.replace(sys.argv[1] + ".tmp", sys.argv[1])' "$CONFIG" "$PROJECT_ID"
fi

CREATED=0
STATE=$(gcloud projects describe "$PROJECT_ID" --format='value(lifecycleState)' 2>/dev/null) || true
if [ "$STATE" = ACTIVE ]; then
  echo "skip: project $PROJECT_ID already exists"
elif [ "$STATE" = DELETE_REQUESTED ]; then
  echo "ERROR: project $PROJECT_ID is DELETE_REQUESTED (deleted, kept for 30 days)." >&2
  echo "Restore it with 'gcloud projects undelete $PROJECT_ID' or clear project_id in config.json." >&2
  exit 1
else
  echo "==> Creating project $PROJECT_ID"
  # The label marks projects this script owns: only they get the cleanup below.
  if ! gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME" --labels=created-by=bootstrap; then
    echo "ERROR: could not create project $PROJECT_ID, the id may be taken." >&2
    echo "Clear project_id in config.json to get a new id and run again." >&2
    exit 1
  fi
  CREATED=1
fi

if [ "$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)')" = True ]; then
  echo "skip: billing is already enabled for $PROJECT_ID"
else
  if [ -z "${BILLING_ACCOUNT:-}" ]; then
    mapfile -t OPEN_ACCOUNTS < <(gcloud billing accounts list --filter=open=true --format='value(name.basename())')
    if [ "${#OPEN_ACCOUNTS[@]}" != 1 ]; then
      echo "ERROR: found ${#OPEN_ACCOUNTS[@]} open billing accounts, expected exactly one." >&2
      echo "Run again with: BILLING_ACCOUNT=<id> ./bootstrap.sh" >&2
      exit 1
    fi
    BILLING_ACCOUNT=${OPEN_ACCOUNTS[0]}
  fi
  echo "==> Linking $PROJECT_ID to billing account ...${BILLING_ACCOUNT: -4}"
  gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
fi

echo "==> Enabling APIs in $PROJECT_ID"
gcloud services enable "${APIS[@]}" --project="$PROJECT_ID"

# Only projects created by this script are cleaned up: an existing project may rely on them.
if [ "$(gcloud projects describe "$PROJECT_ID" --format='value(labels.created-by)')" != bootstrap ]; then
  echo "skip: $PROJECT_ID was not created by bootstrap.sh, its default account and network are left as they are"
else
  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
  DEFAULT_SA=$PROJECT_NUMBER-compute@developer.gserviceaccount.com
  echo "==> Waiting for the default Compute Engine account $DEFAULT_SA"
  if ! retry gcloud iam service-accounts describe "$DEFAULT_SA" --project="$PROJECT_ID" >/dev/null; then
    echo "ERROR: $DEFAULT_SA did not appear." >&2
    exit 1
  fi
  if [ "$CREATED" = 1 ]; then
    echo "==> Waiting for Google to grant roles/editor to $DEFAULT_SA"
    retry default_sa_has_editor || true
  fi
  if default_sa_has_editor; then
    echo "==> Removing roles/editor from $DEFAULT_SA (our VMs use their own accounts)"
    gcloud projects remove-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$DEFAULT_SA" --role=roles/editor \
      --condition=None --quiet >/dev/null
    if default_sa_has_editor; then
      echo "ERROR: $DEFAULT_SA still has roles/editor." >&2
      exit 1
    fi
  else
    echo "skip: $DEFAULT_SA has no roles/editor"
  fi

  if gcloud compute networks describe default --project="$PROJECT_ID" >/dev/null 2>&1; then
    VMS=$(gcloud compute instances list --project="$PROJECT_ID" --filter='networkInterfaces.network~/default$' --format='value(name)')
    if [ -n "$VMS" ]; then
      echo "WARNING: network 'default' is used by: $VMS. Not deleting it."
    else
      echo "==> Deleting network 'default': its firewall rules open SSH and RDP to 0.0.0.0/0"
      mapfile -t RULES < <(gcloud compute firewall-rules list --project="$PROJECT_ID" --filter='network~/default$' --format='value(name)')
      for rule in "${RULES[@]}"; do
        gcloud compute firewall-rules delete "$rule" --project="$PROJECT_ID" --quiet
      done
      gcloud compute networks delete default --project="$PROJECT_ID" --quiet
    fi
  else
    echo "skip: no network 'default'"
  fi
fi
