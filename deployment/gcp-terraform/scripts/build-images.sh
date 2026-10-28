#!/usr/bin/env bash
set -Eeuo pipefail

scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project=$(cd "$scripts/../../.." && pwd)
config=${DEPLOYMENT_CONFIG:-$project/deployment/config/deployment.json}
registry=$(jq -er '.google.region + "-docker.pkg.dev/" + .google.project_id + "/" + .registry.repository_id' "$config")
version=$(jq -er '.application.image_version' "$config")
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
