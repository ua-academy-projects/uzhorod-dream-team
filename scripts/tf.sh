#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"

[[ $# -gt 0 ]] || die "usage: $0 <terraform command> [args...]"
cmd=$1
shift

need terraform gcloud jq
config_check
PROJECT=$(project_id) || exit 1
use_sa_key
TF_VAR_config_file=$(realpath "$CONFIG")
export TF_VAR_config_file

args=()
if [[ $cmd == init ]]; then
  args=(
    "-backend-config=bucket=$PROJECT-tfstate"
    "-backend-config=prefix=iss/main"
  )
fi

exec terraform -chdir="$ROOT/infra" "$cmd" "${args[@]}" "$@"
