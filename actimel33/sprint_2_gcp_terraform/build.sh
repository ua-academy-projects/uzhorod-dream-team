#!/usr/bin/env bash
# Builds the four images in Cloud Build and pushes them to Artifact Registry,
# tagged with the current commit. Needs the gcloud configuration of the project.
set -euo pipefail
cd "$(dirname "$0")"

# The tag names a commit, so the commit must hold exactly what gets built.
if ! git diff --quiet HEAD -- . || [ -n "$(git ls-files --others --exclude-standard -- .)" ]; then
  echo "Uncommitted changes: commit first, the image tag is the commit." >&2
  exit 1
fi

project=$(gcloud config get-value project 2>/dev/null)
tag=$(git rev-parse --short=12 HEAD)

# Runs as crypto-build (push to the registry only).
gcloud builds submit . \
  --config=cloudbuild.yaml \
  --substitutions="_TAG=$tag" \
  --service-account="projects/$project/serviceAccounts/crypto-build@$project.iam.gserviceaccount.com" \
  --gcs-source-staging-dir="gs://$project-build-source/source"

echo
echo "Pushed. Deploy it: image_tag = \"$tag\" in terraform/terraform.tfvars, then terraform apply."