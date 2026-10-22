#!/usr/bin/env bash
# Admin SSH to an internal VM (weather-vm, fetcher-vm, history-vm) only through bastion-vm.
# sshd lets the user vagrant log in only from two addresses:
#   10.0.2.2    - NAT of VirtualBox: vagrant ssh and provisioning (Vagrant keeps its access);
#   BASTION_IP  - internal address of bastion-vm (10.10.10.13): "ssh weather/fetcher/history"
#                 from WSL with ProxyJump.
# SSH from the other internal VMs is refused. WSL and Windows cannot reach the internal
# network at all; through the NAT ports the key of the owner is refused too (from= in ssh-key.sh).
# Only sshd is changed: the ports of the site, PostgreSQL, RabbitMQ and Redis are not touched.
# Running it again is safe: the file is written anew every time.
set -euo pipefail

if [[ ! "${BASTION_IP:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "BASTION_IP must be an IPv4 address" >&2
  exit 1
fi

# Address of the VirtualBox NAT gateway: vagrant ssh comes from it (port forwarding 2222 -> 22).
vagrant_nat_ip=10.0.2.2

conf=/etc/ssh/sshd_config.d/10-weather-bastion.conf
cat > "$conf" <<EOF
# Written by provision/ssh-access.sh (weather-history). Do not edit by hand.
# user@address: vagrant only from Vagrant (NAT) and from bastion-vm.
AllowUsers vagrant@$vagrant_nat_ip vagrant@$BASTION_IP
EOF
chmod 0644 "$conf"

# A broken config would stop sshd and lock out Vagrant too, so it is checked first.
if ! sshd -t; then
  rm -f "$conf"
  echo "sshd config check failed, $conf removed" >&2
  exit 1
fi

# reload: sshd reads the config again, open sessions (also this one) are kept.
systemctl try-reload-or-restart ssh.service
sshd -T | grep '^allowusers'
