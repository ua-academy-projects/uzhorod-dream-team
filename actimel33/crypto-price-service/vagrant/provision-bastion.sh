#!/usr/bin/env bash
# Bastion: the only way in from outside. User jump may forward to :22 of the
# project VMs and nothing else — no shell, no terminal (see its authorized_keys).
set -euo pipefail

id jump >/dev/null 2>&1 || useradd --create-home --shell /bin/sh jump
install -d -o root -g jump -m 0750 /home/jump/.ssh
# root-owned: jump cannot widen its own permissions.
install -o root -g jump -m 0640 /tmp/bastion_authorized_keys /home/jump/.ssh/authorized_keys
rm -f /tmp/bastion_authorized_keys

cat > /etc/ssh/sshd_config.d/10-bastion.conf <<'CONF'
# Keys only; VERBOSE logs the key fingerprint of every login (audit).
PasswordAuthentication no
KbdInteractiveAuthentication no
LogLevel VERBOSE
# jump from anywhere; vagrant only from the Vagrant management network.
AllowUsers jump vagrant@192.168.121.1
CONF
# cloud-init's drop-in turns password login back on; files are read in order, first value wins.
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
sshd -t
systemctl reload ssh