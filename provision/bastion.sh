#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "=== Configuring Bastion VM ==="

apt-get update
apt-get install -y fail2ban ufw


cat > /etc/ssh/sshd_config.d/01-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
MaxAuthTries 3
EOF

# Validate SSH configuration before restarting
sshd -t
systemctl restart ssh

# Configure local firewall
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp

ufw --force enable

# Enable Fail2Ban
systemctl enable --now fail2ban

echo "=== Bastion configuration completed ==="