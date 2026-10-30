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
config["project"]["id"] = sys.argv[2]
with open(sys.argv[1] + ".tmp", "w") as f:
    json.dump(config, f, indent=4, ensure_ascii=False)
    f.write("\n")
os.replace(sys.argv[1] + ".tmp", sys.argv[1])' "$CONFIG" "$PROJECT_ID"
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

read_config() {
  echo "==> gcloud account: $(gcloud config get-value account)"
  # TODO move to secrets
  PROJECT_ID=$(config_value project id)
  PROJECT_ID_PREFIX=$(config_value bootstrap project_id_prefix)
  PROJECT_NAME=$(config_value bootstrap project_name)
  REGION=$(config_value project region)
  SA_NAME=$(config_value bootstrap terraform_service_account)
  STATE_PREFIX=$(config_value bootstrap state_prefix)
  mapfile -t APIS < <(config_value bootstrap apis)
  mapfile -t ROLES < <(config_value bootstrap terraform_roles)

  [ -n "${APIS[0]:-}" ] || die "bootstrap.apis in config.json is empty."
  [[ "$SA_NAME" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] \
    || die "bootstrap.terraform_service_account '$SA_NAME' is not a valid account name."
  [[ "$STATE_PREFIX" =~ ^[A-Za-z0-9/_.-]+$ ]] \
    || die "bootstrap.state_prefix '$STATE_PREFIX' may only have letters, digits and / _ . -"
}

create_project() {
  local state
  if [ -z "$PROJECT_ID" ]; then
    PROJECT_ID=$PROJECT_ID_PREFIX-$(openssl rand -hex 3)
    [[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] \
      || die "'$PROJECT_ID' is not a valid project id, check bootstrap.project_id_prefix."
    # Saved before create, so an interrupted run reuses the id.
    echo "==> project.id is empty: new project id $PROJECT_ID, saved to config.json"
    save_project_id
  fi

  state=$(gcloud projects describe "$PROJECT_ID" --format='value(lifecycleState)' 2>/dev/null) || true
  if [ "$state" = ACTIVE ]; then
    echo "skip: project $PROJECT_ID already exists"
    return
  fi
  if [ "$state" = DELETE_REQUESTED ]; then
    die "project $PROJECT_ID is DELETE_REQUESTED (deleted, kept for 30 days).
Restore it with 'gcloud projects undelete $PROJECT_ID' or clear project.id in config.json."
  fi

  echo "==> Creating project $PROJECT_ID"
  # The cleanup steps run only in projects with this label.
  gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME" --labels=created-by=bootstrap \
    || die "could not create project $PROJECT_ID, the id may be taken.
Clear project.id in config.json to get a new id and run again."
}

name_resources() {
  BUCKET=$PROJECT_ID-tfstate
  SA_EMAIL=$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com
  KEY_FILE=${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/$PROJECT_ID-terraform.json
}

link_billing() {
  local accounts
  if [ "$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)')" = True ]; then
    echo "skip: billing is already enabled for $PROJECT_ID"
    return
  fi
  if [ -z "${BILLING_ACCOUNT:-}" ]; then
    mapfile -t accounts < <(gcloud billing accounts list --filter=open=true --format='value(name.basename())')
    [ "${#accounts[@]}" = 1 ] || die "found ${#accounts[@]} open billing accounts, expected exactly one.
Run again with: BILLING_ACCOUNT=<id> ./bootstrap.sh"
    BILLING_ACCOUNT=${accounts[0]}
  fi
  echo "==> Linking $PROJECT_ID to billing account ...${BILLING_ACCOUNT: -4}"
  gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
}

enable_apis() {
  COMPUTE_WAS_ON=$(gcloud services list --enabled --project="$PROJECT_ID" --filter=config.name=compute.googleapis.com \
    --format='value(config.name)') || COMPUTE_WAS_ON=""
  echo "==> Enabling APIs in $PROJECT_ID"
  # Right after billing is linked, enabling fails for a while.
  retry gcloud services enable "${APIS[@]}" --project="$PROJECT_ID" || die "could not enable the APIs in $PROJECT_ID."
}

created_by_bootstrap() {
  [ "$(gcloud projects describe "$PROJECT_ID" --format='value(labels.created-by)')" = bootstrap ]
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
  if [ -z "$COMPUTE_WAS_ON" ]; then
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

create_state_bucket() {
  if gcloud storage buckets describe "gs://$BUCKET" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "skip: state bucket gs://$BUCKET already exists"
  else
    echo "==> Creating state bucket gs://$BUCKET"
    gcloud storage buckets create "gs://$BUCKET" --project="$PROJECT_ID" --location="$REGION" \
      --uniform-bucket-level-access --public-access-prevention
  fi
  echo "==> Versioning on, public access off for gs://$BUCKET"
  gcloud storage buckets update "gs://$BUCKET" --versioning --uniform-bucket-level-access --public-access-prevention
}

create_terraform_account() {
  local role
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
}

key_is_valid() {
  local key_id keys
  key_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("private_key_id", ""))' "$KEY_FILE" 2>/dev/null) \
    || key_id=""
  keys=$(gcloud iam service-accounts keys list --iam-account="$SA_EMAIL" --project="$PROJECT_ID" --managed-by=user \
    --format='value(name.basename())')
  [ -n "$key_id" ] && grep -qx "$key_id" <<< "$keys"
}

create_key() {
  if [ -f "$KEY_FILE" ] && key_is_valid; then
    echo "skip: key $KEY_FILE is still valid"
  else
    echo "==> Creating key $KEY_FILE"
    rm -f "$KEY_FILE"
    (umask 077 && retry gcloud iam service-accounts keys create "$KEY_FILE" --iam-account="$SA_EMAIL" --project="$PROJECT_ID") \
      || die "could not create a key for $SA_EMAIL. If it already has 10 keys, delete old ones, see:
  gcloud iam service-accounts keys list --iam-account=$SA_EMAIL --project=$PROJECT_ID"
  fi
  chmod 600 "$KEY_FILE"
  [ "$(stat -c %a "$KEY_FILE")" = 600 ] \
    || die "$KEY_FILE is not 600, the disk ignores permissions (a Windows drive?). Keep the key on the Linux disk."
}

write_backend_config() {
  echo "==> Writing $BACKEND_FILE"
  cat > "$BACKEND_FILE" <<EOF
bucket = "$BUCKET"
prefix = "$STATE_PREFIX"
EOF
}

print_next_steps() {
  echo
  echo "Bootstrap of $PROJECT_ID is done. New IAM grants can take a minute or two to work. Next:"
  echo "  export GOOGLE_APPLICATION_CREDENTIALS=$KEY_FILE    # if GOOGLE_APPLICATION_CREDENTIALS is not set, Terraform runs as you"
  echo "  cd $(cd "$DIR/../terraform" && pwd)"
  echo "  terraform init -reconfigure -backend-config=backend.hcl"
  echo "  terraform plan"
}

main() {
  read_config
  create_project
  name_resources
  link_billing
  enable_apis
  if created_by_bootstrap; then
    remove_default_sa_editor
    delete_default_network
  else
    echo "skip: $PROJECT_ID was not created by bootstrap.sh, its default account and network are left as they are"
  fi
  create_state_bucket
  create_terraform_account
  create_key
  write_backend_config
  print_next_steps
}

main "$@"
