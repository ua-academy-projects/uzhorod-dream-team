#!/bin/bash

set -euo pipefail

VM_NAME="${1:?Missing VM name}"
VM_HOST="${2:?Missing VM host}"

SSH_DIR="$HOME/.ssh"
KNOWN_HOSTS="$SSH_DIR/known_hosts"
CONFIG_FILE="$SSH_DIR/config"
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

#public host key in vm
KEY_FILE="$PROJECT_DIR/.vagrant/machines/$VM_NAME/virtualbox/${VM_NAME}_host_key.pub"

if [[ ! -f "$KEY_FILE" ]]; then
    echo "SSH host key not found: $KEY_FILE" >&2
    exit 1
fi

KEY=$(cat "$KEY_FILE")

# if ! ssh-keygen -F "$VM_HOST" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
#     printf '%s %s\n' "$VM_HOST" "$KEY" >> "$KNOWN_HOSTS"
# fi

ssh-keygen -R "$VM_HOST" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
printf '%s %s\n' "$VM_HOST" "$KEY" >> "$KNOWN_HOSTS"

#private key used by vagrant
IDENTITY_FILE="$PROJECT_DIR/.vagrant/machines/$VM_NAME/virtualbox/private_key"

if [[ ! -f "$IDENTITY_FILE" ]]; then
    echo "Private key not found: $IDENTITY_FILE" >&2
    exit 1
fi

TEMP_FILE=$(mktemp)

awk -v host="$VM_NAME" '
    $1 == "Host" && $2 == host { skip=1; next }
    $1 == "Host" { skip=0 }
    !skip { print }
' "$CONFIG_FILE" > "$TEMP_FILE"

if [ "$VM_NAME" = "bastion" ]; then
    cat >> "$TEMP_FILE" <<EOF

Host bastion
    HostName $VM_HOST
    User vagrant
    Port 22
    IdentityFile $IDENTITY_FILE
    IdentitiesOnly yes
    StrictHostKeyChecking yes
EOF
else
    cat >> "$TEMP_FILE" <<EOF

Host $VM_NAME
    HostName $VM_HOST
    User vagrant
    Port 22
    ProxyJump bastion
    IdentityFile $IDENTITY_FILE
    IdentitiesOnly yes
    StrictHostKeyChecking yes
EOF
fi

mv "$TEMP_FILE" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"