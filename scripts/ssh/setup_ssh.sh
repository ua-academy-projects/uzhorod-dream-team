#!/bin/bash

set -euo pipefail

VM_NAME="${1:?Missing VM name}"
SSH_DIR="/home/vagrant/.ssh"

# write hot_key.pub for Mac
mkdir -p "/vagrant/.vagrant/machines/${VM_NAME}/virtualbox"
cat /etc/ssh/ssh_host_ed25519_key.pub \
    > "/vagrant/.vagrant/machines/${VM_NAME}/virtualbox/${VM_NAME}_host_key.pub"

[ "$VM_NAME" = "bastion" ] && exit 0

if [ "$VM_NAME" == "database" ]; then
    sudo mkdir -p "$SSH_DIR"
    sudo chown vagrant:vagrant "$SSH_DIR"
    sudo chmod 700 "$SSH_DIR"

    if [ ! -f "$SSH_DIR/logfetcher" ]; then
       sudo -u vagrant ssh-keygen -t ed25519 -f "$SSH_DIR/logfetcher" -N "" >/dev/null 2>&1
    fi

    sudo chmod 600 "$SSH_DIR/logfetcher"
    sudo chmod 644 "$SSH_DIR/logfetcher.pub"
    
    sudo chown vagrant:vagrant \
        "$SSH_DIR/logfetcher" "$SSH_DIR/logfetcher.pub"

    cp "$SSH_DIR/logfetcher.pub" \
        "/vagrant/.vagrant/machines/${VM_NAME}/logfetcher-${VM_NAME}.pub"

else    
    AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"

    sudo touch "$AUTHORIZED_KEYS"
    sudo chmod 700 "$SSH_DIR"
    sudo chmod 600 "$AUTHORIZED_KEYS"
    sudo chown -R vagrant:vagrant "$SSH_DIR"

    key="/vagrant/.vagrant/machines/database/logfetcher-database.pub"

    [ -f "$key" ] || exit 1

    public_key=$(cat "$key")

    if ! sudo grep -qxF "$public_key" "$AUTHORIZED_KEYS"; then
        echo "$public_key" | sudo tee -a "$AUTHORIZED_KEYS" >/dev/null
    fi
fi
