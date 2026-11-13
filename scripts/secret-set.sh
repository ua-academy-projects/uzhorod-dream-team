#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"

need gcloud jq
config_check
[[ $# -eq 1 ]] || die "usage: $0 NAME (value is read from stdin)"
name=$1
is_secret "$name" || die "unknown secret $name; expected one of: ${SECRETS[*]}"
PROJECT=$(project_id) || exit 1

if [[ -t 0 ]]; then
  read -rsp "value for $name: " value
  echo
else
  IFS= read -r value || true
fi
value=${value%$'\r'}
[[ -n $value ]] || die "empty value for $name"

printf '%s' "$value" | gcloud secrets versions add "$name" --data-file=- --project "$PROJECT" >/dev/null
echo "added a new version of $name"
