#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

readonly DEFAULT_REGION=us-central1
readonly DEFAULT_STATE_PREFIX=terraform/state
readonly SERVICE_ACCOUNT_NAME=terraform
readonly IAM_ATTEMPTS=6
readonly IAM_RETRY_SECONDS=2
readonly MAX_RETRY_SECONDS=16
readonly TERRAFORM_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ANSIBLE_DIR=$(cd "$TERRAFORM_DIR/../ansible" && pwd)

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [--no-interactive] [--help]

Interactive by default. --no-interactive reads the environment without prompting.

BOOTSTRAP_PROJECT_ID       Required Google Cloud project ID
BOOTSTRAP_BILLING_ACCOUNT  Required billing account ID
BOOTSTRAP_REGION           Default: us-central1
BOOTSTRAP_ZONE             Default: <region>-a
BOOTSTRAP_BUCKET           Default: <project-id>-tfstate
BOOTSTRAP_STATE_PREFIX     Default: terraform/state
DEPLOYMENT_CONFIG          Default: <config-dir>/deployment.json
BOOTSTRAP_CONFIG_DIR       Default: ~/.config/kyiv-air
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

prompt() {
  local name=$1 answer
  read -r -p "$name [${!name:-}]: " answer || die "Input ended. Use --no-interactive for unattended runs."
  [[ -z "$answer" ]] || printf -v "$name" '%s' "$answer"
}

retry_iam() {
  local attempt delay=$IAM_RETRY_SECONDS output
  for (( attempt=1; attempt<=IAM_ATTEMPTS; attempt++ )); do
    if output=$("$@" 2>&1); then return 0; fi
    case "$output" in
      *'does not exist'*|*'not found'*|*'NOT_FOUND'*|*'concurrent policy'*|*'Please retry'*) ;;
      *) printf '%s\n' "$output" >&2; return 1 ;;
    esac
    if (( attempt == IAM_ATTEMPTS )); then
      printf '%s\n' "$output" >&2
      return 1
    fi
    printf 'Waiting for IAM propagation (%s/%s)...\n' "$attempt" "$IAM_ATTEMPTS" >&2
    sleep "$delay"
    delay=$((delay * 2))
    (( delay <= MAX_RETRY_SECONDS )) || delay=$MAX_RETRY_SECONDS
  done
}

# Options
interactive=true
for argument in "$@"; do
  case "$argument" in
    --help|-h) usage; exit 0 ;;
    --no-interactive) interactive=false ;;
    *) usage >&2; die "Unknown argument: $argument" ;;
  esac
done

# Dependencies
for dependency in gcloud jq awk; do
  command -v "$dependency" >/dev/null || die "Install $dependency before running bootstrap."
done

# Reading config paths
BOOTSTRAP_CONFIG_DIR=${BOOTSTRAP_CONFIG_DIR:-$HOME/.config/kyiv-air}
if "$interactive"; then prompt BOOTSTRAP_CONFIG_DIR; fi
BOOTSTRAP_CONFIG_DIR=${BOOTSTRAP_CONFIG_DIR/#\~/$HOME}
DEPLOYMENT_CONFIG=${DEPLOYMENT_CONFIG:-$BOOTSTRAP_CONFIG_DIR/deployment.json}
if "$interactive"; then prompt DEPLOYMENT_CONFIG; fi
DEPLOYMENT_CONFIG=${DEPLOYMENT_CONFIG/#\~/$HOME}
if "$interactive"; then prompt BOOTSTRAP_OUTPUT_DIR; fi
BOOTSTRAP_OUTPUT_DIR=${BOOTSTRAP_OUTPUT_DIR/#\~/$HOME}

# Reading project ID & billing account
BOOTSTRAP_PROJECT_ID=${BOOTSTRAP_PROJECT_ID:-}
BOOTSTRAP_BILLING_ACCOUNT=${BOOTSTRAP_BILLING_ACCOUNT:-}
if "$interactive"; then
  prompt BOOTSTRAP_PROJECT_ID
  prompt BOOTSTRAP_BILLING_ACCOUNT
fi
missing=()
for name in BOOTSTRAP_PROJECT_ID BOOTSTRAP_BILLING_ACCOUNT DEPLOYMENT_CONFIG BOOTSTRAP_OUTPUT_DIR; do
  [[ -n "${!name}" ]] || missing+=("$name")
done
if (( ${#missing[@]} )); then
  printf 'Missing required environment variable: %s\n' "${missing[@]}" >&2
  exit 1
fi

# Reading parameters with defaults
BOOTSTRAP_REGION=${BOOTSTRAP_REGION:-$DEFAULT_REGION}
if "$interactive"; then prompt BOOTSTRAP_REGION; fi
BOOTSTRAP_ZONE=${BOOTSTRAP_ZONE:-$BOOTSTRAP_REGION-a}
BOOTSTRAP_BUCKET=${BOOTSTRAP_BUCKET:-$BOOTSTRAP_PROJECT_ID-tfstate}
BOOTSTRAP_STATE_PREFIX=${BOOTSTRAP_STATE_PREFIX:-$DEFAULT_STATE_PREFIX}
if "$interactive"; then
  for name in BOOTSTRAP_ZONE BOOTSTRAP_BUCKET BOOTSTRAP_STATE_PREFIX; do
    prompt "$name"
  done
fi

install -d -m 0700 "$BOOTSTRAP_CONFIG_DIR"
install -d -m 0700 "$BOOTSTRAP_OUTPUT_DIR"
BOOTSTRAP_CONFIG_DIR=$(cd "$BOOTSTRAP_CONFIG_DIR" && pwd)
BOOTSTRAP_OUTPUT_DIR=$(cd "$BOOTSTRAP_OUTPUT_DIR" && pwd)

readonly CONFIG_FILE=$(realpath "$DEPLOYMENT_CONFIG")
readonly BACKEND_FILE=$BOOTSTRAP_OUTPUT_DIR/backend.ini
readonly KEY_FILE=$BOOTSTRAP_OUTPUT_DIR/terraform-key.json
readonly ENV_FILE=$BOOTSTRAP_OUTPUT_DIR/env.sh
readonly ACCOUNT=$SERVICE_ACCOUNT_NAME@$BOOTSTRAP_PROJECT_ID.iam.gserviceaccount.com

jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null || die "Expected a JSON object in $CONFIG_FILE."

# Reading existing Terraform Backend config
if [[ -e "$BACKEND_FILE" ]]; then
  existing_bucket=$(awk -F ' = ' '$1 == "bucket" { gsub(/"/, "", $2); print $2 }' "$BACKEND_FILE")
  existing_prefix=$(awk -F ' = ' '$1 == "prefix" { gsub(/"/, "", $2); print $2 }' "$BACKEND_FILE")
  [[ "$existing_bucket" == "$BOOTSTRAP_BUCKET" && "$existing_prefix" == "$BOOTSTRAP_STATE_PREFIX" ]] \
    || die "Existing $BACKEND_FILE conflicts with selected settings."
  chmod 0600 "$BACKEND_FILE"
fi

# Validating existing key
if [[ -e "$KEY_FILE" ]]; then
  jq -e --arg project "$BOOTSTRAP_PROJECT_ID" --arg email "$ACCOUNT" '
    .type == "service_account" and .project_id == $project and .client_email == $email
    and (.private_key_id | type == "string" and length > 0)
    and (.private_key | type == "string" and length > 0)
  ' "$KEY_FILE" >/dev/null || die "Invalid or mismatched local key: $KEY_FILE. Recover the correct credential before rerunning."
  chmod 0600 "$KEY_FILE"
fi

# Checking user auth
caller=$(gcloud auth list --filter=status:ACTIVE --format='value(account)')
[[ -n "$caller" ]] || die 'Authenticate first with gcloud auth login.'

# Creating project
projects=$(gcloud projects list --filter="projectId=$BOOTSTRAP_PROJECT_ID" --format=json)
if ! jq -e --arg project "$BOOTSTRAP_PROJECT_ID" 'any(.[]; .projectId == $project)' <<< "$projects" >/dev/null; then
  gcloud projects create "$BOOTSTRAP_PROJECT_ID" --name="$BOOTSTRAP_PROJECT_ID" --quiet
fi
# Validating project
project=$(gcloud projects describe "$BOOTSTRAP_PROJECT_ID" --format=json)
jq -e '.lifecycleState == "ACTIVE"' <<< "$project" >/dev/null || die 'Project is not active.'

# Validating billing account link to project
billing=$(gcloud billing projects describe "$BOOTSTRAP_PROJECT_ID" --format=json)
linked_account=$(jq -r '.billingAccountName // ""' <<< "$billing")
if [[ -z "$linked_account" ]]; then
  gcloud billing projects link "$BOOTSTRAP_PROJECT_ID" --billing-account="$BOOTSTRAP_BILLING_ACCOUNT" --quiet
elif [[ "$linked_account" != "billingAccounts/$BOOTSTRAP_BILLING_ACCOUNT" ]]; then
  die 'Project is linked to a different billing account; refusing to change it.'
fi
billing=$(gcloud billing projects describe "$BOOTSTRAP_PROJECT_ID" --format=json)
jq -e '.billingEnabled == true' <<< "$billing" >/dev/null || die 'Billing is not enabled. Check the linked billing account.'

# Enabling services
gcloud services enable \
  cloudresourcemanager.googleapis.com cloudbilling.googleapis.com serviceusage.googleapis.com \
  iam.googleapis.com storage.googleapis.com compute.googleapis.com \
  secretmanager.googleapis.com artifactregistry.googleapis.com sqladmin.googleapis.com dns.googleapis.com \
  --project="$BOOTSTRAP_PROJECT_ID" --quiet

# Checking zone accessibility
gcloud compute zones describe "$BOOTSTRAP_ZONE" --project="$BOOTSTRAP_PROJECT_ID" --format='value(name)' >/dev/null

# Creating service account
accounts=$(gcloud iam service-accounts list --project="$BOOTSTRAP_PROJECT_ID" --format=json)
if ! jq -e --arg email "$ACCOUNT" 'any(.[]; .email == $email)' <<< "$accounts" >/dev/null; then
  gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name='Terraform deployment' --project="$BOOTSTRAP_PROJECT_ID" --quiet
fi
retry_iam gcloud iam service-accounts describe "$ACCOUNT" --project="$BOOTSTRAP_PROJECT_ID" --format=json

# Adding roles to service account
for role in \
  roles/compute.admin roles/iam.serviceAccountAdmin roles/iam.serviceAccountUser \
  roles/cloudsql.admin roles/dns.admin roles/artifactregistry.admin roles/secretmanager.admin roles/secretmanager.secretAccessor roles/serviceusage.serviceUsageConsumer \
  roles/resourcemanager.projectIamAdmin roles/servicedirectory.editor; do
  retry_iam gcloud projects add-iam-policy-binding "$BOOTSTRAP_PROJECT_ID" \
    --member="serviceAccount:$ACCOUNT" --role="$role" --condition=None --quiet
done

# Validating service account key
keys=$(gcloud iam service-accounts keys list --iam-account="$ACCOUNT" --managed-by=user --project="$BOOTSTRAP_PROJECT_ID" --format=json)
if [[ -f "$KEY_FILE" ]]; then
  key_id=$(jq -er '.private_key_id' "$KEY_FILE")
  jq -e --arg id "$key_id" 'any(.[]; (.name | endswith("/" + $id)) and (.disabled != true))' <<< "$keys" >/dev/null \
    || die 'The local key is absent or disabled. Recover credentials before rerunning.'
elif [[ $(jq 'length' <<< "$keys") -gt 0 ]]; then
  die "Remote service-account keys exist, but $KEY_FILE is missing. Restore a matching key or explicitly revoke lost keys before rerunning."
fi

# Create service account key
if [[ ! -f "$KEY_FILE" ]]; then
  gcloud iam service-accounts keys create "$KEY_FILE" --iam-account="$ACCOUNT" --project="$BOOTSTRAP_PROJECT_ID" --quiet \
    || die "Key creation failed. Check service-account key policy and recover any partially created key before rerunning."
  chmod 0600 "$KEY_FILE"
fi

# Creating bucket
buckets=$(gcloud storage buckets list --project="$BOOTSTRAP_PROJECT_ID" --format='value(name)')
bucket_exists=false
while read -r name; do
  if [[ "$name" == "$BOOTSTRAP_BUCKET" || "$name" == "gs://$BOOTSTRAP_BUCKET" || "$name" == "gs://$BOOTSTRAP_BUCKET/" ]]; then
    bucket_exists=true
  fi
done <<< "$buckets"
if ! "$bucket_exists"; then
  gcloud storage buckets create "gs://$BOOTSTRAP_BUCKET" --project="$BOOTSTRAP_PROJECT_ID" \
    --location="$BOOTSTRAP_REGION" --uniform-bucket-level-access --public-access-prevention --quiet
fi

# Validating bucket
bucket=$(gcloud storage buckets describe "gs://$BOOTSTRAP_BUCKET" --raw --project="$BOOTSTRAP_PROJECT_ID" --format=json)
project_number=$(jq -er '.projectNumber | tostring' <<< "$project")
jq -e --arg project "$project_number" --arg region "$BOOTSTRAP_REGION" '
  (.projectNumber | tostring) == $project and (.location | ascii_downcase) == $region
' <<< "$bucket" >/dev/null || die 'State bucket belongs to a different project or location.'

# Updating bucket config
gcloud storage buckets update "gs://$BOOTSTRAP_BUCKET" --project="$BOOTSTRAP_PROJECT_ID" \
  --uniform-bucket-level-access --public-access-prevention --quiet

# Add storage roles to service account
retry_iam gcloud storage buckets add-iam-policy-binding "gs://$BOOTSTRAP_BUCKET" \
  --project="$BOOTSTRAP_PROJECT_ID" --member="serviceAccount:$ACCOUNT" --role=roles/storage.objectAdmin --quiet

# Saving new config
config_temp=$(mktemp "${CONFIG_FILE}.XXXXXX")
jq --arg project "$BOOTSTRAP_PROJECT_ID" --arg region "$BOOTSTRAP_REGION" --arg zone "$BOOTSTRAP_ZONE" '
  .google.project_id = $project | .google.region = $region | .google.zone = $zone
' "$CONFIG_FILE" > "$config_temp"
chmod --reference="$CONFIG_FILE" "$config_temp"
mv "$config_temp" "$CONFIG_FILE"
if [[ ! -f "$BACKEND_FILE" ]]; then
  printf 'bucket = "%s"\nprefix = "%s"\n' "$BOOTSTRAP_BUCKET" "$BOOTSTRAP_STATE_PREFIX" > "$BACKEND_FILE"
fi

# Saving sourceable environment and initialization commands
{
  printf '#!/usr/bin/env bash\n\n'
  printf 'export GOOGLE_APPLICATION_CREDENTIALS=%q\n' "$KEY_FILE"
  printf 'export TF_VAR_config_path=%q\n' "$CONFIG_FILE"
  printf 'export DEPLOYMENT_CONFIG=%q\n' "$CONFIG_FILE"
  printf 'export ANSIBLE_CONFIG=%q\n\n' "$ANSIBLE_DIR/ansible.cfg"
  printf 'terraform -chdir=%q init %q\n' "$TERRAFORM_DIR" "-backend-config=$BACKEND_FILE"
} > "$ENV_FILE"
chmod 0600 "$ENV_FILE"

printf '\nBootstrap complete. Source this file to set the environment and initialize Terraform:\n\n'
printf 'source %q\n' "$ENV_FILE"
