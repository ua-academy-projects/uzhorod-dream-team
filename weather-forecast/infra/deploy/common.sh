#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$DEPLOY_DIR/../.." && pwd)
CONFIG=${WEATHER_CONFIG:-$HOME/.config/weather-forecast/deployment.json}
SECRETS=${WEATHER_SECRETS:-$ROOT/var/deploy/secrets.env}
TF_DIR=$ROOT/infra/terraform
KEY=${WEATHER_SSH_KEY:-$HOME/.ssh/weather_vm}
KNOWN_HOSTS=$ROOT/var/deploy/known_hosts

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for cmd in jq ssh terraform; do
  command -v "$cmd" >/dev/null || die "$cmd is required"
done
[[ -r $CONFIG ]] || die "config not found: $CONFIG"
[[ -r $KEY ]] || die "SSH key not found: $KEY (set WEATHER_SSH_KEY)"

cfg() { jq -r "$@" "$CONFIG"; }

vm_attr() {
  cfg --arg vm "$1" --arg key "$2" \
    '(.vms.instances[$vm] // error("unknown VM: \($vm)")) as $vm_config | (.vms.defaults + $vm_config)[$key]'
}

bastion_of() {
  cfg --arg subnet "$(vm_attr "$1" subnet)" \
    '.subnets as $s | .vms.defaults as $d | $s[$subnet].network as $net
     | [.vms.instances | to_entries[] | select(($d + .value) as $v | $v.role == "bastion" and $s[$v.subnet].network == $net) | .key][0]
       // error("no bastion in network \($net)")'
}

SSH_USER=${WEATHER_SSH_USER:-$USER}
SSH_PORT=$(cfg .ssh.port)
JUMP_USER=$(cfg .ssh.jump_user)
jq -e --arg user "$SSH_USER" '.ssh.public_keys | has($user)' "$CONFIG" >/dev/null ||
  die "$SSH_USER is not in ssh.public_keys (set WEATHER_SSH_USER)"

EXTERNAL_IPS=$(terraform -chdir="$TF_DIR" output -json external_ips 2>/dev/null) ||
  die "no Terraform outputs; run terraform apply in $TF_DIR"

mkdir -p "$(dirname "$KNOWN_HOSTS")"
CONTROL_DIR=$(mktemp -d)
trap 'rm -rf "$CONTROL_DIR"' EXIT

SSH_BASE=(
  -i "$KEY"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o ServerAliveInterval=30
  -p "$SSH_PORT"
)

remote() {
  local vm=$1 role ip bastion bastion_ip proxy tty=()
  shift
  role=$(vm_attr "$vm" role)
  [[ $role != bastion ]] || die "$vm is a bastion; it only forwards SSH"
  ip=$(vm_attr "$vm" ip)
  bastion=$(bastion_of "$vm")
  bastion_ip=$(jq -er --arg b "$bastion" '.[$b] // error("no external IP for \($b)")' <<<"$EXTERNAL_IPS")
  proxy="ssh $(printf '%q ' "${SSH_BASE[@]}")-W %h:%p $(printf '%q' "$JUMP_USER@$bastion_ip")"
  [[ ${REMOTE_TTY:-0} == 1 ]] && tty=(-t)
  ssh "${SSH_BASE[@]}" "${tty[@]}" \
    -o ControlMaster=auto -o ControlPath="$CONTROL_DIR/%C" -o ControlPersist=60 \
    -o ProxyCommand="$proxy" "$SSH_USER@$ip" "$@"
}
