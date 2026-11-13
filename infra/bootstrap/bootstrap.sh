#!/usr/bin/env bash
# bootstrap: only what Terraform cannot create for itself.
#   project + billing, APIs, the state bucket and ONE service account (terraform) it impersonates.
# Everything else (VM service accounts, ansible, artifacts bucket, their roles) is Terraform: modules/iam.
# Idempotent: safe to re-run, and works against an already existing project.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

APIS=(
  compute.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com # service account impersonation
  cloudresourcemanager.googleapis.com
  serviceusage.googleapis.com
  storage.googleapis.com
  sqladmin.googleapis.com
  servicenetworking.googleapis.com
  logging.googleapis.com
  oslogin.googleapis.com
  osconfig.googleapis.com
  iap.googleapis.com
  monitoring.googleapis.com
)

# wide on purpose: terraform also manages IAM (modules/iam), Cloud SQL and DNS
ROLES=(
  roles/compute.admin
  roles/storage.admin
  roles/iam.serviceAccountUser
  roles/iam.serviceAccountAdmin
  roles/resourcemanager.projectIamAdmin
  roles/cloudsql.admin
  roles/dns.admin
  roles/servicenetworking.networksAdmin
  roles/serviceusage.serviceUsageAdmin
  roles/osconfig.osPolicyAssignmentAdmin # Ops Agent policies (modules/ops_agent)
  roles/monitoring.admin                 # alert policies, notification channels, uptime checks (modules/ops_agent)
  roles/logging.configWriter             # log-based metrics (modules/ops_agent)
)

step() { echo; echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

# IAM changes right after creating a service account can fail until it propagates
retry() {
  local n
  for n in 1 2 3 4 5 6; do
    "$@" && return 0
    [ "$n" = 6 ] || { echo "  retrying in $((n * 5))s..." >&2; sleep $((n * 5)); }
  done
  return 1
}

load_config() {
  command -v gcloud >/dev/null || die "gcloud is not installed"
  [ -f bootstrap.env ] || die "infra/bootstrap/bootstrap.env is missing: cp bootstrap.env.example bootstrap.env and fill it in"
  set -a
  # shellcheck disable=SC1091
  . ./bootstrap.env
  set +a
  for v in PROJECT_ID PROJECT_NAME BILLING_ACCOUNT ORG_ID; do
    [ -n "${!v:-}" ] || die "bootstrap.env: $v is empty"
  done

  REGION=${REGION:-europe-west4}
  OUT_DIR=..
  BUCKET=${STATE_BUCKET:-${PROJECT_ID}-tfstate}
  SA="terraform@${PROJECT_ID}.iam.gserviceaccount.com"
  P=(--project "$PROJECT_ID" --quiet)

  ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
  [ -n "$ACCOUNT" ] || die "no active gcloud account, run: gcloud auth login"
  case $ACCOUNT in
  *.gserviceaccount.com) ME="serviceAccount:$ACCOUNT" ;;
  *) ME="user:$ACCOUNT" ;;
  esac
}

create_project() {
  step "1. project ${PROJECT_ID} (as ${ACCOUNT})"
  if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
    local parent
    parent=$(gcloud projects describe "$PROJECT_ID" --format='value(parent.id)')
    echo "    exists (organization: ${parent:-none})"
    [ "$parent" = "$ORG_ID" ] || echo "warning: project is not in organization $ORG_ID, not moving it" >&2
  else
    gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME" --organization="$ORG_ID" \
      || die "could not create the project; you need roles/resourcemanager.projectCreator on organization $ORG_ID"
  fi
  # linking again counts against the billing account's project quota, so only link when needed
  if [ "$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null)" = True ]; then
    echo "    billing already enabled"
  else
    gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT" >/dev/null
  fi
}

enable_apis() {
  step "2. APIs"
  gcloud services enable "${APIS[@]}" "${P[@]}"
}

create_state_bucket() {
  step "3. state bucket gs://${BUCKET}"
  gcloud storage buckets describe "gs://$BUCKET" "${P[@]}" >/dev/null 2>&1 \
    || gcloud storage buckets create "gs://$BUCKET" "${P[@]}" --location="$REGION" \
      --uniform-bucket-level-access --public-access-prevention

  # keep the last 20 noncurrent versions of the state, never the live one
  local lifecycle
  lifecycle=$(mktemp)
  echo '{"rule":[{"action":{"type":"Delete"},"condition":{"numNewerVersions":20,"isLive":false}}]}' >"$lifecycle"
  gcloud storage buckets update "gs://$BUCKET" "${P[@]}" --versioning --lifecycle-file="$lifecycle" >/dev/null
  rm -f "$lifecycle"
}

create_service_account() {
  step "4. service account ${SA}"
  gcloud iam service-accounts describe "$SA" "${P[@]}" >/dev/null 2>&1 \
    || gcloud iam service-accounts create terraform "${P[@]}" --display-name="Terraform"
}

grant_roles() {
  for role in "${ROLES[@]}"; do
    echo "    ${role}"
    retry gcloud projects add-iam-policy-binding "$PROJECT_ID" --quiet --condition=None \
      --member="serviceAccount:$SA" --role="$role" >/dev/null
  done
}

allow_impersonation() {
  echo "    ${ME} may act as it (roles/iam.serviceAccountTokenCreator)"
  retry gcloud iam service-accounts add-iam-policy-binding "$SA" "${P[@]}" \
    --member="$ME" --role=roles/iam.serviceAccountTokenCreator >/dev/null
}

write_terraform_env() {
  step "5. terraform.env and backend.hcl in $(readlink -f "$OUT_DIR")"
  install -m 600 /dev/null "$OUT_DIR/terraform.env"
  cat >"$OUT_DIR/terraform.env" <<EOF
# Generated by bootstrap/bootstrap.sh. Do NOT commit (git-ignored). Before Terraform:
#   source terraform.env
# Terraform then acts AS ${SA} (impersonation: your login + short-lived tokens, no key file)
export GOOGLE_IMPERSONATE_SERVICE_ACCOUNT="${SA}"
export GOOGLE_BACKEND_IMPERSONATE_SERVICE_ACCOUNT="${SA}"
# who may impersonate the ansible service account that Terraform creates (modules/iam)
export TF_VAR_operator_member="${ME}"
EOF
  install -m 600 /dev/null "$OUT_DIR/backend.hcl"
  echo "bucket = \"${BUCKET}\"" >"$OUT_DIR/backend.hcl"
}

main() {
  load_config
  create_project
  enable_apis
  create_state_bucket
  create_service_account
  grant_roles
  allow_impersonation
  write_terraform_env

  cat <<EOF

==> done

project       ${PROJECT_ID} (${REGION})
state bucket  gs://${BUCKET}
terraform SA  ${SA}

next (the artifacts bucket and all VM/ansible service accounts are created by Terraform):
  cd .. && source terraform.env && terraform init -backend-config=backend.hcl
  terraform apply
EOF
}

main "$@"
