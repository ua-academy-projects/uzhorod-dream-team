#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"

usage() {
  echo "usage: $0 <playbook relative to ansible/playbooks, e.g. site.yml or runbooks/os-update.yml> [ansible-playbook args]" >&2
  exit 2
}

[[ $# -ge 1 && $1 != -* ]] || usage
playbook=$ROOT/ansible/playbooks/$1
shift
[[ -f $playbook ]] || die "playbook $playbook not found"

dry=${ISS_ANSIBLE_DRY:-}
need jq python3
config_check
PROJECT=$(project_id) || exit 1
if [[ -z $dry ]]; then
  use_sa_key
  export GCP_AUTH_KIND=serviceaccount
  export GCP_SERVICE_ACCOUNT_FILE=$GOOGLE_APPLICATION_CREDENTIALS
fi
ansible_venv

generated=${ISS_ANSIBLE_GENERATED:-$ROOT/ansible/.generated}
inventory=$generated/inventory/iss.gce.yml
mkdir -p "$generated/inventory"
rm -f "$generated/inventory/gcp.gcp_compute.yml" "$generated/context.json"

key=$(cfg '.access.ssh_public_key')
key=${key%.pub}
[[ $key == \~/* ]] && key=$HOME/${key#\~/}

jq -n --arg project "$PROJECT" --arg zone "$(cfg '.project.zone')" --arg prefix "$(cfg '.project.name_prefix')" \
  --arg key "$key" --argjson port "$(cfg '.access.ssh_port // 22')" '{
  plugin: "iss.platform.gce",
  project: $project,
  zones: [$zone],
  auth_kind: "serviceaccount",
  filters: {"iss-prefix": $prefix},
  group_labels: ["iss-key", "iss-role"],
  bastion_label: "iss-role",
  bastion_value: "bastion",
  admin_user: "iss-admin",
  jump_user: "jump",
  ssh_port: $port,
  private_key_file: $key,
  known_hosts_file: "~/.ssh/iss_gcp/known_hosts"
}' > "$inventory"

ISS_CONFIG=$(realpath "$CONFIG")
export ISS_CONFIG
cmd=(ansible-playbook -i "$inventory" "$playbook" "$@")
printf '+ ISS_CONFIG=%q' "$ISS_CONFIG"
printf ' %q' "${cmd[@]}"
printf '\n'
[[ -n $dry ]] && exit 0
"${cmd[@]}"
