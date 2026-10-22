#!/usr/bin/env bash
# Firewall (ufw) of bastion-vm: only SSH comes in.
# Bastion lets in "ssh bastion" from WSL (host-only) and vagrant ssh / provisioning (NAT).
# The ProxyJump tunnels from bastion to the internal VMs are outgoing, so they are allowed.
# Bastion does not route packets between its networks (net.ipv4.ip_forward = 0).
# Runs every time: the rules are rebuilt from this file.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get install -y ufw

# Start from an empty rule list, so old rules removed from this file disappear too.
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH: "ssh bastion" from WSL and vagrant ssh. Without this rule Vagrant loses access to the VM.
ufw allow 22/tcp comment 'SSH'

ufw --force enable
ufw status verbose
