#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

CONFIG=${WEATHER_CONFIG:-$HOME/.config/weather-forecast/deployment.json}
ENV_FILE=${WEATHER_ENV:-$HOME/.config/weather-forecast/local.env}

die() { echo "error: $*" >&2; exit 1; }
cfg() { jq -er "$@" "$CONFIG"; }
retry() {
  local attempt
  for attempt in 1 2 3 4 5; do
    "$@" && return 0
    sleep $((attempt * 3))
  done
  return 1
}

for tool in gcloud jq terraform; do
  command -v "$tool" >/dev/null || die "$tool is not installed"
done
[[ -f $CONFIG ]] || die "config not found: $CONFIG"
[[ -f $ENV_FILE ]] && source "$ENV_FILE"

: "${PROJECT_ID:?set PROJECT_ID in $ENV_FILE}"
: "${BILLING_ACCOUNT:?set BILLING_ACCOUNT in $ENV_FILE}"
: "${GOOGLE_APPLICATION_CREDENTIALS:?set GOOGLE_APPLICATION_CREDENTIALS in $ENV_FILE}"

gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q . ||
  die "no active gcloud account, run: gcloud auth login"

PROJECT_NAME=$(cfg '.project.name')
REGION=$(cfg '.project.region')
SA_NAME=$(cfg '.bootstrap.terraform_sa.name')
STATE_PREFIX=$(cfg '.bootstrap.state.prefix')
mapfile -t APIS < <(cfg '.bootstrap.apis[]')
mapfile -t ROLES < <(cfg '.bootstrap.terraform_sa.roles[]')
SA_EMAIL="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"
BUCKET="gs://$PROJECT_ID-tfstate"
KEY_FILE=$GOOGLE_APPLICATION_CREDENTIALS

echo "project $PROJECT_ID"
gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1 ||
  gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME"

echo "billing"
current_billing=$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingAccountName)')
[[ $current_billing == "billingAccounts/$BILLING_ACCOUNT" ]] ||
  gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"

echo "apis"
gcloud services enable "${APIS[@]}" --project="$PROJECT_ID"

echo "service account $SA_EMAIL"
gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1 ||
  gcloud iam service-accounts create "$SA_NAME" --project="$PROJECT_ID" --display-name="Terraform"

for role in "${ROLES[@]}"; do
  echo "role $role"
  retry gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" --role="$role" --condition=None --quiet >/dev/null
done

echo "state bucket $BUCKET"
gcloud storage buckets describe "$BUCKET" --project="$PROJECT_ID" >/dev/null 2>&1 ||
  gcloud storage buckets create "$BUCKET" --project="$PROJECT_ID" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update "$BUCKET" --versioning >/dev/null
retry gcloud storage buckets add-iam-policy-binding "$BUCKET" \
  --member="serviceAccount:$SA_EMAIL" --role=roles/storage.objectAdmin >/dev/null

echo "key $KEY_FILE"
if [[ ! -s $KEY_FILE ]]; then
  mkdir -p "$(dirname "$KEY_FILE")"
  (umask 077 && gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account="$SA_EMAIL" --project="$PROJECT_ID") || { rm -f "$KEY_FILE"; die "key creation failed"; }
fi

echo "terraform backend"
GOOGLE_APPLICATION_CREDENTIALS=$KEY_FILE retry terraform -chdir="$ROOT/infra/terraform" init \
  -input=false -migrate-state -force-copy \
  -backend-config="bucket=${BUCKET#gs://}" -backend-config="prefix=$STATE_PREFIX"
