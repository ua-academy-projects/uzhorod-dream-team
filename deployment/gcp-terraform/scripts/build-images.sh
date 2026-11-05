#!/usr/bin/env bash
set -Eeuo pipefail

scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project=$(cd "$scripts/../../.." && pwd)
config=${DEPLOYMENT_CONFIG:-${TF_VAR_config_path:-}}
if [[ -z "$config" ]]; then
  echo "Missing env var: set DEPLOYMENT_CONFIG or TF_VAR_config_path (exported by the env.sh that bootstrap.sh generates) to the deployment.json path." >&2
  exit 1
fi
if [[ ! -f "$config" ]]; then
  echo "Config file not found: $config" >&2
  exit 1
fi
registry=$(jq -er '.google.region + "-docker.pkg.dev/" + .google.project_id' "$config")
repository=$(jq -er '.registry.id // "kyiv-air"' "$config")
registry=$registry/$repository
version=$(jq -er '.registry.image_version' "$config")
registry_host=${registry%%/*}
gcloud auth configure-docker "$registry_host" --quiet

if (( $# == 0 )); then set -- fetcher history ui migrate; fi
for component in "$@"; do
  case "$component" in
    fetcher) context=fetcher; target= ;;
    history) context=history; target=runtime ;;
    ui) context=ui; target= ;;
    migrate) context=history; target=migrate ;;
    *) echo "Unknown component: $component. Use fetcher, history, ui, or migrate." >&2; exit 1 ;;
  esac
  image=$registry/$component:$version
  args=(--platform linux/amd64 --tag "$image")
  if [[ -n "$target" ]]; then args+=(--target "$target"); fi
  docker build "${args[@]}" "$project/$context"
  docker push "$image"
done
