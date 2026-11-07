#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../../config.json"

PROJECT_ID="$(jq -er '.project_id' "$CONFIG_FILE")"
PROJECT_NAME="$(jq -er '.bootstrap.project_name' "$CONFIG_FILE")"
REGION="$(jq -er '.region' "$CONFIG_FILE")"
BILLING_ACCOUNT_ID="$(jq -r '.bootstrap.billing_account_id // ""' "$CONFIG_FILE")"
FOLDER_ID="$(jq -r '.bootstrap.folder_id // ""' "$CONFIG_FILE")"
ORGANIZATION_ID="$(jq -r '.bootstrap.organization_id // ""' "$CONFIG_FILE")"
SERVICE_ACCOUNT_ID="$(jq -er '.bootstrap.service_account_id' "$CONFIG_FILE")"
SERVICE_ACCOUNT_NAME="$(jq -er '.bootstrap.service_account_name' "$CONFIG_FILE")"
BUCKET_NAME="$(jq -er '.bootstrap.bucket_name' "$CONFIG_FILE")"
STATE_PREFIX="$(jq -er '.bootstrap.state_prefix' "$CONFIG_FILE")"

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

  if [[ "$(jq -r '.database.provider' "$CONFIG_FILE")" == cloud_sql ]]; then
    gcloud services enable sqladmin.googleapis.com servicenetworking.googleapis.com \
      --project="$PROJECT_ID" --quiet
  fi
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
    resourcemanager.projectIamAdmin
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

ensure_cloud_sql() {
  [[ "$(jq -r '.database.provider' "$CONFIG_FILE")" == cloud_sql ]] || return 0
  local instance network region zone version tier edition database instances details ranges peerings databases
  instance="$(jq -er '.cloud_sql.instance_name' "$CONFIG_FILE")"
  network="$(jq -er '.network.name' "$CONFIG_FILE")"
  region="$(jq -er '.cloud_sql.region' "$CONFIG_FILE")"
  zone="$(jq -er '.cloud_sql.zone' "$CONFIG_FILE")"
  version="$(jq -er '.cloud_sql.database_version' "$CONFIG_FILE")"
  tier="$(jq -er '.cloud_sql.tier' "$CONFIG_FILE")"
  edition="$(jq -er '.cloud_sql.edition' "$CONFIG_FILE")"
  database="$(jq -er '.database.name' "$CONFIG_FILE")"

  # The VPC is owned by Terraform, including on a brand-new project.
  # Target only networking: the placeholder SSH CIDR never reaches a firewall.
  local networks
  networks="$(gcloud compute networks list --project="$PROJECT_ID" --format=json)"
  if ! jq -e --arg name "$network" 'any(.[]; .name == $name)' <<< "$networks" >/dev/null; then
    (
      source "${SCRIPT_DIR}/terraform.env.sh"
      terraform -chdir="${SCRIPT_DIR}/.." init -input=false \
        -backend-config="${SCRIPT_DIR}/backend.hcl"
      terraform -chdir="${SCRIPT_DIR}/.." apply -input=false -auto-approve \
        -target=module.network -var=admin_ip_cidr=127.0.0.1/32
    )
  fi

  peerings="$(gcloud services vpc-peerings list --project="$PROJECT_ID" \
    --network="$network" --service=servicenetworking.googleapis.com --format=json)"
  if [[ "$(jq 'length' <<< "$peerings")" == 0 ]]; then
    local range_name="${network}-cloud-sql"
    ranges="$(gcloud compute addresses list --global --project="$PROJECT_ID" --format=json)"
    if ! jq -e --arg name "$range_name" 'any(.[]; .name == $name)' <<< "$ranges" >/dev/null; then
      gcloud compute addresses create "$range_name" --global --purpose=VPC_PEERING \
        --prefix-length=16 --network="$network" --project="$PROJECT_ID" --quiet
    fi
    gcloud services vpc-peerings connect --network="$network" \
      --service=servicenetworking.googleapis.com --ranges="$range_name" \
      --project="$PROJECT_ID" --quiet
  fi

  instances="$(gcloud sql instances list --project="$PROJECT_ID" --format=json)"
  if ! jq -e --arg name "$instance" 'any(.[]; .name == $name)' <<< "$instances" >/dev/null; then
    local flags=(--no-assign-ip --no-deletion-protection)
    if [[ "$(jq -r '.cloud_sql.public_ip' "$CONFIG_FILE")" == true ]]; then
      flags[0]=--assign-ip
    fi
    if [[ "$(jq -r '.cloud_sql.deletion_protection' "$CONFIG_FILE")" == true ]]; then
      flags[1]=--deletion-protection
    fi
    gcloud sql instances create "$instance" --project="$PROJECT_ID" \
      --database-version="$version" --edition="$edition" --tier="$tier" \
      --region="$region" --zone="$zone" \
      --network="projects/${PROJECT_ID}/global/networks/${network}" \
      "${flags[@]}" --quiet
  fi
  details="$(gcloud sql instances describe "$instance" --project="$PROJECT_ID" --format=json)"
  jq -e --arg region "$region" --arg version "$version" --arg network "/networks/$network" '
    .state == "RUNNABLE" and .region == $region and .databaseVersion == $version and
    (.settings.ipConfiguration.privateNetwork | endswith($network)) and
    any(.ipAddresses[]; .type == "PRIVATE")
  ' <<< "$details" >/dev/null || fail 'Cloud SQL state, version, region or private network differs; existing instance was not modified.'
  databases="$(gcloud sql databases list --instance="$instance" --project="$PROJECT_ID" --format=json)"
  if ! jq -e --arg name "$database" 'any(.[]; .name == $name)' <<< "$databases" >/dev/null; then
    gcloud sql databases create "$database" --instance="$instance" --project="$PROJECT_ID" --quiet
  fi
  echo "Cloud SQL ready: ${PROJECT_ID}:${region}:${instance}, database ${database}"
  echo 'For a new instance, configure the application DB user/password from Secret Manager; postgres backend also requires SQL-only PGMQ (see DataFetcher/README.md).'
}

validate_config() {
  jq -e '
    (.database.provider == "cloud_sql" or .database.provider == "container") and
    (.compute.application.app_backend == "hybrid" or .compute.application.app_backend == "postgres")
  ' "$CONFIG_FILE" >/dev/null || fail 'Invalid database.provider or compute.application.app_backend.'
}

main() {
  validate_config
  ensure_project
  configure_billing
  enable_apis
  ensure_service_account
  grant_terraform_permissions
  ensure_state_bucket
  ensure_service_account_key
  write_terraform_settings
  ensure_cloud_sql

  echo 'Done. Run: source gcp-terra/bootstrap/terraform.env.sh'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
