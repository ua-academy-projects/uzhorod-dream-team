#!/bin/bash
# Writes ~/.ssh/config.d/gcp_crypto_modules.conf for whoever runs it:
# the bastion through IAP, every other VM through the bastion.
set -euo pipefail
umask 077

DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG=$DIR/../terraform_resources_configuration/config.json
SSH_CONFIG=$HOME/.ssh/config.d/gcp_crypto_modules.conf

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# config_value KEY [KEY...] prints the value of config.json at that path.
config_value() {
  python3 -I -c '
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2:]:
    value = value[key]
print(value)' "$CONFIG" "$@"
}

PROJECT=$(config_value project id)
BASTION=$(config_value ssh bastion)
[ -n "$PROJECT" ] || die "project.id in config.json is empty, run bootstrap/bootstrap.sh first."

mapfile -t VMS < <(gcloud compute instances list --project="$PROJECT" --format='value(name,zone.basename())')
[ -n "${VMS[0]:-}" ] || die "no VMs in $PROJECT, run terraform apply first."

BASTION_ZONE=""
for vm in "${VMS[@]}"; do
  read -r name zone <<< "$vm"
  if [ "$name" = "$BASTION" ]; then
    BASTION_ZONE=$zone
  fi
done
[ -n "$BASTION_ZONE" ] || die "the bastion VM '$BASTION' (ssh.bastion in config.json) is not in $PROJECT."

# The OS Login user appears after the first login with gcloud.
USER_NAME=$(gcloud compute os-login describe-profile --format='value(posixAccounts[0].username)')
[ -n "$USER_NAME" ] || die "you have no OS Login user yet. Log in once, it also creates your SSH key:
  gcloud compute ssh $BASTION --tunnel-through-iap --project=$PROJECT --zone=$BASTION_ZONE"

mkdir -p "$(dirname "$SSH_CONFIG")"
{
  cat <<EOF
# Written by ssh-config.sh for $USER_NAME.

Host $BASTION
    HostName $BASTION
    User $USER_NAME
    IdentityFile ~/.ssh/google_compute_engine
    ProxyCommand gcloud compute start-iap-tunnel $BASTION 22 --listen-on-stdin --project=$PROJECT --zone=$BASTION_ZONE
EOF
  for vm in "${VMS[@]}"; do
    read -r name zone <<< "$vm"
    if [ "$name" != "$BASTION" ]; then
      # The bastion resolves the internal DNS name, which stays the same when the VM is recreated.
      cat <<EOF

Host $name
    HostName $name.$zone.c.$PROJECT.internal
    User $USER_NAME
    IdentityFile ~/.ssh/google_compute_engine
    ProxyJump $BASTION
EOF
    fi
  done
} > "$SSH_CONFIG.tmp"
chmod 600 "$SSH_CONFIG.tmp"
mv "$SSH_CONFIG.tmp" "$SSH_CONFIG"
echo "==> Wrote $SSH_CONFIG for $USER_NAME"

if ! grep -qs "config.d/" "$HOME/.ssh/config"; then
  echo "Add this line to the top of ~/.ssh/config: Include config.d/*"
fi
