#!/usr/bin/env bash

set -euo pipefail
cd "$(dirname "$0")"

APIS=(
  cloudresourcemanager.googleapis.com serviceusage.googleapis.com orgpolicy.googleapis.com
  iam.googleapis.com iamcredentials.googleapis.com
  compute.googleapis.com storage.googleapis.com secretmanager.googleapis.com logging.googleapis.com
  sqladmin.googleapis.com servicenetworking.googleapis.com monitoring.googleapis.com artifactregistry.googleapis.com
)


ROLES=(
  roles/compute.admin                     
  roles/iam.serviceAccountAdmin           
  roles/iam.serviceAccountUser            
  roles/secretmanager.admin               
  roles/storage.admin                     
  roles/resourcemanager.projectIamAdmin   
  roles/serviceusage.serviceUsageConsumer 
  roles/cloudsql.admin                    
  roles/servicenetworking.networksAdmin
  roles/logging.configWriter
  roles/monitoring.editor
)

KEY_POLICIES=(iam.disableServiceAccountKeyCreation iam.managed.disableServiceAccountKeyCreation)

step() { echo; echo "==> $*"; }

retry() {
  for _ in $(seq 17); do "$@" 2>/dev/null && return 0; sleep 10; done
  "$@"
}


load_config() {
  [ -f bootstrap.env ] || { echo "infra/bootstrap/bootstrap.env is missing: cp bootstrap.env.example bootstrap.env and fill it in" >&2; exit 1; }
  set -a; source ./bootstrap.env; set +a
  for v in PROJECT_ID PROJECT_NAME BILLING_ACCOUNT MY_IP; do
    [ -n "${!v:-}" ] || { echo "bootstrap.env: $v is empty" >&2; exit 1; }
  done

  command -v jq >/dev/null || { echo "jq is missing: sudo apt install jq" >&2; exit 1; }
  REGION=$(jq -er '.clouds.gcp.location.regions[.region]' ../config.json)
  ZONE=$(jq -er '.clouds.gcp.location.zones[.zone]' ../config.json)

  if [ -n "${AWS_ADMIN_PROFILE:-}" ]; then
    command -v aws >/dev/null || { echo "the AWS CLI is missing: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2; exit 1; }
    PREFIX=$(jq -er .prefix ../config.json)
    REGION_AWS=$(jq -er '.clouds.aws.location.regions[.region]' ../config.json)
    AWS_USER="${PREFIX}-terraform"      
    A=(--profile "$AWS_ADMIN_PROFILE")
  fi

  ME=$(gcloud config get-value account 2>/dev/null)
  BUCKET="${PROJECT_ID}-tfstate"
  SA="terraform@${PROJECT_ID}.iam.gserviceaccount.com"
  KEY_FILE="$PWD/terraform-key.json"
  P=(--project "$PROJECT_ID" --quiet)
}


create_project() {
  step "1. project ${PROJECT_ID} (as ${ME})"
  gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1 \
    || gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME"
  gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT" >/dev/null
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


  local lifecycle
  lifecycle=$(mktemp)
  echo '{"rule":[{"action":{"type":"Delete"},"condition":{"numNewerVersions":20,"isLive":false}}]}' > "$lifecycle"
  gcloud storage buckets update "gs://$BUCKET" "${P[@]}" --versioning --lifecycle-file="$lifecycle" >/dev/null
  rm -f "$lifecycle"
}


create_service_account() {
  step "4. service account ${SA}"
  gcloud iam service-accounts describe "$SA" "${P[@]}" >/dev/null 2>&1 \
    || gcloud iam service-accounts create terraform "${P[@]}" --display-name="Terraform (envs/dev)"
}


grant_roles() {
  for role in "${ROLES[@]}"; do
    echo "    ${role}"
    retry gcloud projects add-iam-policy-binding "$PROJECT_ID" --quiet --condition=None \
      --member="serviceAccount:$SA" --role="$role" >/dev/null
  done
}


allow_keys_in_project() {
  local parent_type org
  read -r parent_type org < <(gcloud projects describe "$PROJECT_ID" --format='value(parent.type,parent.id)')
  step "5. service account keys allowed in ${PROJECT_ID} only"
  if [ "$parent_type" != organization ]; then
    echo "    the project is not in an organization: nothing to allow"; return
  fi
  echo "    ${ME}: roles/orgpolicy.policyAdmin on organization ${org}"
  retry gcloud organizations add-iam-policy-binding "$org" --quiet --condition=None \
    --member="user:$ME" --role=roles/orgpolicy.policyAdmin >/dev/null

  local policy
  policy=$(mktemp)
  for constraint in "${KEY_POLICIES[@]}"; do
    if ! gcloud org-policies describe "$constraint" --project="$PROJECT_ID" --effective \
           --billing-project="$PROJECT_ID" >/dev/null 2>&1; then
      echo "    ${constraint}: does not exist in this organization, skipped"
      continue
    fi
    printf 'name: projects/%s/policies/%s\nspec:\n  rules:\n  - enforce: false\n' "$PROJECT_ID" "$constraint" > "$policy"
    retry gcloud org-policies set-policy "$policy" --billing-project="$PROJECT_ID" --quiet >/dev/null
    echo "    ${constraint}: not enforced in ${PROJECT_ID}"
  done
  rm -f "$policy"
}


create_key() {
  if [ -s "$KEY_FILE" ]; then
    echo "    key: ${KEY_FILE} exists, kept"; return
  fi
  echo "    key: ${KEY_FILE}"
  (umask 077; retry gcloud iam service-accounts keys create "$KEY_FILE" --iam-account="$SA" "${P[@]}" >/dev/null 2>&1) || {
    rm -f "$KEY_FILE"
    echo "    could not create the key: is the policy still enforced? (it can take a few minutes; run again)" >&2
    exit 1
  }
}


aws_check_identity() {
  local arn
  arn=$(aws sts get-caller-identity "${A[@]}" --query Arn --output text)
  AWS_ACCOUNT=$(aws sts get-caller-identity "${A[@]}" --query Account --output text)
  step "6. AWS account ${AWS_ACCOUNT} (as ${arn})"
  case "$arn" in
    *:root) echo "    that is root: make an admin IAM user and put its profile in AWS_ADMIN_PROFILE" >&2; exit 1 ;;
  esac
}


aws_create_terraform_user() {
  step "7. AWS IAM user ${AWS_USER} (AdministratorAccess), CLI profile ${AWS_USER}"
  aws iam get-user --user-name "$AWS_USER" "${A[@]}" >/dev/null 2>&1 \
    || aws iam create-user --user-name "$AWS_USER" "${A[@]}" --tags Key=app,Value="$PREFIX" Key=managed-by,Value=bootstrap >/dev/null
  aws iam attach-user-policy --user-name "$AWS_USER" "${A[@]}" --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

  if aws configure get aws_access_key_id --profile "$AWS_USER" >/dev/null 2>&1; then
    echo "    key: profile ${AWS_USER} exists, kept"
  else
    echo "    key: profile ${AWS_USER} in ~/.aws/credentials"
    local key_id secret

    read -r key_id secret < <(aws iam create-access-key --user-name "$AWS_USER" "${A[@]}" \
      --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
    [ -n "${secret:-}" ] || { echo "    could not create the key (an IAM user has at most 2: aws iam list-access-keys --user-name ${AWS_USER})" >&2; exit 1; }
    aws configure set aws_access_key_id "$key_id" --profile "$AWS_USER"
    aws configure set aws_secret_access_key "$secret" --profile "$AWS_USER"
  fi
  aws configure set region "$REGION_AWS" --profile "$AWS_USER"

  local account
  account=$(retry aws sts get-caller-identity --profile "$AWS_USER" --query Account --output text)
  [ "$account" = "$AWS_ACCOUNT" ] || { echo "    profile ${AWS_USER} is in account ${account}, not ${AWS_ACCOUNT}" >&2; exit 1; }
}


aws_setup() {
  if [ -z "${AWS_ADMIN_PROFILE:-}" ]; then
    step "6-7. AWS: skipped (AWS_ADMIN_PROFILE in bootstrap.env is empty)"; return
  fi
  aws_check_identity
  aws_create_terraform_user
}


write_terraform_env() {
  step "8. infra/bootstrap/terraform.env"
  install -m 600 /dev/null terraform.env
  cat > terraform.env <<EOF
#   source infra/bootstrap/terraform.env
# Terraform then acts AS ${SA}, with its key: no personal login needed (works after \`gcloud auth logout\`).
# Only what is NOT in infra/config.json (in git): the key, the state bucket, the project, your IP.
unset GOOGLE_IMPERSONATE_SERVICE_ACCOUNT GOOGLE_BACKEND_IMPERSONATE_SERVICE_ACCOUNT
export GOOGLE_APPLICATION_CREDENTIALS="${KEY_FILE}"   # the provider and the state backend
export TF_STATE_BUCKET="${BUCKET}"                     # terraform init -backend-config="bucket=\$TF_STATE_BUCKET"
export TF_VAR_project_id="${PROJECT_ID}"
export TF_VAR_my_ip="${MY_IP}"
EOF
  [ -n "${AWS_ADMIN_PROFILE:-}" ] || return 0
  cat >> terraform.env <<EOF
# AWS: Terraform acts AS IAM user ${AWS_USER} (its key: profile ${AWS_USER} in ~/.aws/credentials), and only in this account
export AWS_PROFILE="${AWS_USER}"
export AWS_REGION="${REGION_AWS}"
export TF_VAR_aws_account_id="${AWS_ACCOUNT}"
EOF
}


write_ansible_inventory() {
  step "9. infra/bootstrap/inventory.gcp.yml"
  cat > inventory.gcp.yml <<EOF
plugin: google.cloud.gcp_compute
projects: [${PROJECT_ID}]
zones: [${ZONE}]
auth_kind: serviceaccount
service_account_file: ${KEY_FILE}
filters:
  - labels.vm:*
hostnames:
  - name
keyed_groups:
  - key: labels.vm
    prefix: vm
compose:
  vm: labels.vm
  private_ip: networkInterfaces[0].networkIP
  # the bastion by its public IP, every other VM by its private IP (reached through the bastion)
  ansible_host: (networkInterfaces[0].accessConfigs | default([{}]))[0].natIP | default(networkInterfaces[0].networkIP)
EOF
}


main() {
  load_config
  create_project
  enable_apis
  create_state_bucket
  create_service_account
  grant_roles
  allow_keys_in_project
  create_key
  aws_setup
  write_terraform_env
  write_ansible_inventory

  echo
  echo "Done. Next:  source infra/bootstrap/terraform.env && cd infra/envs/dev && terraform init -backend-config=\"bucket=\$TF_STATE_BUCKET\""
}

main "$@"
