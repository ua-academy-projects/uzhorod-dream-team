#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"

need gcloud jq
config_check
PROJECT=$(project_id) || exit 1
TF_SA=terraform@$PROJECT.iam.gserviceaccount.com
key=$(sa_key_path) || exit 1
new=$key.new
trap 'rm -f "$new"' EXIT

mapfile -t old < <(gcloud iam service-accounts keys list --iam-account "$TF_SA" --managed-by=user \
  --project "$PROJECT" --format='value(name)')

mkdir -p "$(dirname "$key")"
(umask 077; gcloud iam service-accounts keys create "$new" --iam-account "$TF_SA" --project "$PROJECT" >/dev/null 2>&1) \
  || die "cannot create a new key for $TF_SA"
CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=$new gcloud auth print-access-token >/dev/null 2>&1 \
  || die "the new key does not work; the old key is kept"
mv -f "$new" "$key"
echo "new key written to $key"

for id in "${old[@]}"; do
  [[ -n $id ]] || continue
  gcloud iam service-accounts keys delete "${id##*/}" --iam-account "$TF_SA" --project "$PROJECT" --quiet >/dev/null
  echo "deleted old key ${id##*/}"
done
