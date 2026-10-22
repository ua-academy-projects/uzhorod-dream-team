#!/usr/bin/env bash
# Writes the host keys (ssh-ed25519) of the four VMs (bastion and three internal) into ~/.ssh/known_hosts of WSL,
# so that "ssh bastion/weather/fetcher/history" can check the server key (StrictHostKeyChecking yes).
# The keys are read through vagrant ssh, not from the network: Vagrant already logs in
# with its own key over the local port forwarding of VirtualBox.
# Run from WSL in the project folder once, and again after a VM is created anew:
#   ./ssh-trust.sh
# Prints only the fingerprints of the host keys.
set -euo pipefail
cd "$(dirname "$0")"

known="$HOME/.ssh/known_hosts"
install -d -m 0700 "$HOME/.ssh"
touch "$known"
chmod 0600 "$known"

for vm in bastion-vm weather-vm fetcher-vm history-vm; do
  # The VM name is the HostKeyAlias in ~/.ssh/config (see README).
  key=$(vagrant ssh "$vm" -c "cat /etc/ssh/ssh_host_ed25519_key.pub" 2>/dev/null |
    tr -d '\r' | awk '$1 == "ssh-ed25519" { print $1 " " $2 }')
  if [[ -z "$key" ]]; then
    echo "$vm: host key not read (is the VM running?)" >&2
    exit 1
  fi
  # The old key of this VM is removed first (it changes when the VM is created anew).
  ssh-keygen -R "$vm" -f "$known" >/dev/null 2>&1 || true
  echo "$vm $key" >> "$known"
  echo "$vm: $(echo "$vm $key" | ssh-keygen -lf -)"
done
