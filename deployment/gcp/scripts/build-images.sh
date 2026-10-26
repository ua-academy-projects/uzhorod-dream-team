#!/usr/bin/env bash
set -Eeuo pipefail

scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project=$(cd "$scripts/../../.." && pwd)
output=${IMAGE_DIR:-$project/deployment/gcp/images}
source "$scripts/images.env"

mkdir -p "$output"
if (( $# == 0 )); then set -- fetcher history ui migrate; fi
for component in "$@"; do
  case "$component" in
    fetcher) image=$FETCHER_IMAGE; context=fetcher; target= ;;
    history) image=$HISTORY_IMAGE; context=history; target=runtime ;;
    ui) image=$UI_IMAGE; context=ui; target= ;;
    migrate) image=$MIGRATION_IMAGE; context=history; target=migrate ;;
    *) echo "Unknown component: $component. Use fetcher, history, ui, or migrate." >&2; exit 1 ;;
  esac
  args=(--platform linux/amd64 --tag "$image")
  if [[ -n "$target" ]]; then args+=(--target "$target"); fi
  docker build "${args[@]}" "$project/$context"
  docker image save --output "$output/$component.tar" "$image"
done
