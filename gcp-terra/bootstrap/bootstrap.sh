#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${SCRIPT_DIR}/.tools:${PATH}"
CONFIG_FILE="${SCRIPT_DIR}/bootstrap.local.json"

PROJECT_ID="$(jq -er '.project_id' "$CONFIG_FILE")"
PROJECT_NAME="$(jq -er '.project_name' "$CONFIG_FILE")"
REGION="$(jq -er '.region' "$CONFIG_FILE")"
BILLING_ACCOUNT_ID="$(jq -r '.billing_account_id // ""' "$CONFIG_FILE")"
FOLDER_ID="$(jq -r '.folder_id // ""' "$CONFIG_FILE")"
ORGANIZATION_ID="$(jq -r '.organization_id // ""' "$CONFIG_FILE")"
SERVICE_ACCOUNT_ID="$(jq -er '.service_account_id' "$CONFIG_FILE")"
SERVICE_ACCOUNT_NAME="$(jq -er '.service_account_name' "$CONFIG_FILE")"
BUCKET_NAME="$(jq -er '.bucket_name' "$CONFIG_FILE")"
STATE_PREFIX="$(jq -er '.state_prefix' "$CONFIG_FILE")"

SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
BUCKET_URL="gs://${BUCKET_NAME}"
KEY_DIRECTORY="${SCRIPT_DIR}/.credentials"
KEY_FILE="${KEY_DIRECTORY}/${PROJECT_ID}-${SERVICE_ACCOUNT_ID}.json"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

ensure_project() {
  local existing_project
  local parent_arguments=()

  existing_project="$(gcloud projects list \
    --filter="projectId=${PROJECT_ID}" \
    --format='value(projectId)')"

  if [[ -z "$existing_project" ]]; then
    [[ -n "$BILLING_ACCOUNT_ID" ]] || fail 'Set billing_account_id for a new project.'
    [[ -z "$FOLDER_ID" || -z "$ORGANIZATION_ID" ]] || fail 'Use folder_id or organization_id.'

    if [[ -n "$FOLDER_ID" ]]; then
      parent_arguments=(--folder="$FOLDER_ID")
    elif [[ -n "$ORGANIZATION_ID" ]]; then
      parent_arguments=(--organization="$ORGANIZATION_ID")
    fi

    gcloud projects create "$PROJECT_ID" \
      --name="$PROJECT_NAME" \
      "${parent_arguments[@]}" \
      --quiet
  fi

  PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" \
    --format='value(projectNumber)')"
}

configure_billing() {
  local billing_details current_billing_account billing_enabled

  billing_details="$(gcloud billing projects describe "$PROJECT_ID" --format=json)"
  current_billing_account="$(jq -r '.billingAccountName // ""' <<< "$billing_details")"
  billing_enabled="$(jq -r '.billingEnabled' <<< "$billing_details")"

  if [[ -n "$BILLING_ACCOUNT_ID" && -n "$current_billing_account" &&
        "$current_billing_account" != "billingAccounts/${BILLING_ACCOUNT_ID}" ]]; then
    fail 'Project uses another billing account.'
  fi

  if [[ "$billing_enabled" != true ]]; then
    [[ -n "$BILLING_ACCOUNT_ID" ]] || fail 'Set billing_account_id.'

    gcloud billing projects link "$PROJECT_ID" \
      --billing-account="$BILLING_ACCOUNT_ID" \
      --quiet
  fi
}

enable_apis() {
  gcloud services enable serviceusage.googleapis.com \
    --project="$PROJECT_ID" \
    --quiet

  gcloud services enable \
    cloudresourcemanager.googleapis.com \
    iam.googleapis.com \
    compute.googleapis.com \
    secretmanager.googleapis.com \
    storage.googleapis.com \
    --project="$PROJECT_ID" \
    --quiet
}

ensure_service_account() {
  local service_accounts account_exists

  service_accounts="$(gcloud iam service-accounts list \
    --project="$PROJECT_ID" \
    --format=json)"

  jq -e --arg email "$SERVICE_ACCOUNT_EMAIL" \
    'all(.[] | select(.email == $email); .disabled != true)' \
    <<< "$service_accounts" >/dev/null || fail 'Service account is disabled.'

  account_exists="$(jq --arg email "$SERVICE_ACCOUNT_EMAIL" \
    'any(.[]; .email == $email)' <<< "$service_accounts")"

  if [[ "$account_exists" == false ]]; then
    gcloud iam service-accounts create "$SERVICE_ACCOUNT_ID" \
      --project="$PROJECT_ID" \
      --display-name="$SERVICE_ACCOUNT_NAME" \
      --quiet
  fi
}

grant_terraform_permissions() {
  local role
  local roles=(
    compute.instanceAdmin.v1
    compute.networkAdmin
    compute.securityAdmin
    iam.serviceAccountAdmin
    iam.serviceAccountUser
    secretmanager.admin
    serviceusage.serviceUsageConsumer
  )

  for role in "${roles[@]}"; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
      --role="roles/${role}" \
      --condition=None \
      --quiet >/dev/null
  done
}

ensure_state_bucket() {
  local buckets bucket_exists bucket_details

  buckets="$(gcloud storage buckets list --project="$PROJECT_ID" --format=json)"
  bucket_exists="$(jq --arg name "$BUCKET_NAME" '
    any(.[]; ((.name // "") | ltrimstr("gs://") | rtrimstr("/")) == $name)
  ' <<< "$buckets")"

  if [[ "$bucket_exists" == false ]]; then
    gcloud storage buckets create "$BUCKET_URL" \
      --project="$PROJECT_ID" \
      --location="$REGION" \
      --uniform-bucket-level-access \
      --public-access-prevention \
      --quiet
  fi

  bucket_details="$(gcloud storage buckets describe "$BUCKET_URL" --raw --format=json)"
  jq -e --arg project "$PROJECT_NUMBER" --arg region "$REGION" '
    (.projectNumber | tostring) == $project and
    (.location | ascii_downcase) == $region
  ' <<< "$bucket_details" >/dev/null || fail 'Bucket project or region differs.'

  gcloud storage buckets update "$BUCKET_URL" \
    --project="$PROJECT_ID" \
    --versioning \
    --uniform-bucket-level-access \
    --public-access-prevention \
    --quiet

  gcloud storage buckets add-iam-policy-binding "$BUCKET_URL" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
    --role=roles/storage.objectAdmin \
    --condition=None \
    --quiet >/dev/null
}

ensure_service_account_key() {
  local key_id key_details temporary_directory

  mkdir -p "$KEY_DIRECTORY"
  chmod 700 "$KEY_DIRECTORY"

  # Reuse the local key instead of creating one on every run.
  if [[ ! -s "$KEY_FILE" ]]; then
    temporary_directory="$(mktemp -d "${KEY_DIRECTORY}/export.XXXXXX")"

    if gcloud iam service-accounts keys create "${temporary_directory}/key.json" \
      --project="$PROJECT_ID" \
      --iam-account="$SERVICE_ACCOUNT_EMAIL" \
      --quiet; then
      mv "${temporary_directory}/key.json" "$KEY_FILE"
      rmdir "$temporary_directory"
    else
      rm -f "${temporary_directory}/key.json"
      rmdir "$temporary_directory"
      fail 'Service account key could not be created.'
    fi
  fi

  chmod 600 "$KEY_FILE"
  jq -e --arg email "$SERVICE_ACCOUNT_EMAIL" '
    .type == "service_account" and
    .client_email == $email and
    (.private_key | length > 0)
  ' "$KEY_FILE" >/dev/null || fail 'Invalid local service account key.'

  key_id="$(jq -er '.private_key_id' "$KEY_FILE")"
  key_details="$(gcloud iam service-accounts keys list \
    --iam-account="$SERVICE_ACCOUNT_EMAIL" \
    --project="$PROJECT_ID" \
    --managed-by=user \
    --format=json)"

  jq -e --arg key_id "$key_id" '
    any(.[]; (.name | endswith("/keys/" + $key_id)) and .disabled != true)
  ' <<< "$key_details" >/dev/null || fail 'Service account key is missing or disabled.'
}

write_terraform_settings() {
  {
    echo 'unset GOOGLE_IMPERSONATE_SERVICE_ACCOUNT GOOGLE_BACKEND_IMPERSONATE_SERVICE_ACCOUNT'
    echo 'unset GOOGLE_CREDENTIALS GOOGLE_CLOUD_KEYFILE_JSON GCLOUD_KEYFILE_JSON GOOGLE_BACKEND_CREDENTIALS'
    printf 'export GOOGLE_APPLICATION_CREDENTIALS=%q\n' "$KEY_FILE"
  } > "${SCRIPT_DIR}/terraform.env.sh"

  printf 'bucket = "%s"\nprefix = "%s"\n' \
    "$BUCKET_NAME" "$STATE_PREFIX" > "${SCRIPT_DIR}/backend.hcl"
}

main() {
  ensure_project
  configure_billing
  enable_apis
  ensure_service_account
  grant_terraform_permissions
  ensure_state_bucket
  ensure_service_account_key
  write_terraform_settings

  echo 'Done. Run: source gcp-terra/bootstrap/terraform.env.sh'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
