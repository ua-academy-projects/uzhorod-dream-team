#!/bin/bash

set -euo pipefail

SSH_DIR="/home/vagrant/.ssh"
KNOWN_HOSTS="$SSH_DIR/known_hosts"

while [[ $# -gt 0 ]]; do
    if [[ $# -lt 2 ]]; then
        echo "Error: expected pairs of VM_NAME and VM_HOST" >&2
        exit 1
    fi
    
    VM_NAME="$1"
    VM_HOST="$2"
    shift 2

    HOST_KEY="/vagrant/.vagrant/machines/${VM_NAME}/virtualbox/${VM_NAME}_host_key.pub"

    if [[ ! -f "$HOST_KEY" ]]; then
        echo "SSH host key not found: $HOST_KEY" >&2
        exit 1
    fi

    sudo mkdir -p "$SSH_DIR"
    sudo touch "$KNOWN_HOSTS"
    sudo chown -R vagrant:vagrant "$SSH_DIR"
    sudo chmod 700 "$SSH_DIR"

    sudo -u vagrant ssh-keygen -R "$VM_HOST" \
        -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true

    awk -v host="$VM_HOST" \
        '{print host, $0}' "$HOST_KEY" |
        sudo tee -a "$KNOWN_HOSTS" >/dev/null

    sudo chown vagrant:vagrant "$KNOWN_HOSTS"
    sudo chmod 600 "$KNOWN_HOSTS"

done