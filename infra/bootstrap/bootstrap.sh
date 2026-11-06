#!/usr/bin/env bash

set -euo pipefail
cd "$(dirname "$0")"

APIS=(
  cloudresourcemanager.googleapis.com serviceusage.googleapis.com orgpolicy.googleapis.com
  iam.googleapis.com iamcredentials.googleapis.com
  compute.googleapis.com storage.googleapis.com secretmanager.googleapis.com logging.googleapis.com
  sqladmin.googleapis.com servicenetworking.googleapis.com
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
)

KEY_POLICIES=(iam.disableServiceAccountKeyCreation iam.managed.disableServiceAccountKeyCreation)


step() { echo; echo "==> $*"; }

retry() {
  for _ in $(seq 18); do "$@" && return 0; sleep 10; done
  return 1
}


load_config() {
  [ -f bootstrap.env ] || { echo "infra/bootstrap.env is missing: cp bootstrap.env.example bootstrap.env and fill it in" >&2; exit 1; }
  set -a; source ./bootstrap.env; set +a
  for v in PROJECT_ID PROJECT_NAME BILLING_ACCOUNT REGION ZONE MY_IP; do
    [ -n "${!v:-}" ] || { echo "bootstrap.env: $v is empty" >&2; exit 1; }
  done

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


write_terraform_env() {
  step "6. infra/bootstrap/terraform.env"
  install -m 600 /dev/null terraform.env
  cat > terraform.env <<EOF
# Terraform then acts AS ${SA}, with its key: no personal login needed (works after \`gcloud auth logout\`)
unset GOOGLE_IMPERSONATE_SERVICE_ACCOUNT GOOGLE_BACKEND_IMPERSONATE_SERVICE_ACCOUNT
export GOOGLE_APPLICATION_CREDENTIALS="${KEY_FILE}"   # the provider and the state backend

export GCP_AUTH_KIND=serviceaccount
export GCP_SERVICE_ACCOUNT_FILE="${KEY_FILE}"
export GCP_PROJECT="${PROJECT_ID}"

export TF_STATE_BUCKET="${BUCKET}"
export TF_VAR_project_id="${PROJECT_ID}"
export TF_VAR_region="${REGION}"
export TF_VAR_zone="${ZONE}"
export TF_VAR_my_ip="${MY_IP}"
EOF
}


write_ansible_inventory() {
  step "7. infra/bootstrap/inventory.gcp.yml"
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
  write_terraform_env
  write_ansible_inventory

  echo
  echo "Done. Next:  source infra/bootstrap/terraform.env && cd infra/envs/dev && terraform init -reconfigure -backend-config=\"bucket=\$TF_STATE_BUCKET\""
}

main "$@"
