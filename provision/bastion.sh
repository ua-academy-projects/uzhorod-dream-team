#!/bin/bash
set -e

apt-get update -y
apt-get install -y fail2ban ufw

cat > /etc/ssh/sshd_config.d/01-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
X11Forwarding no
AllowAgentForwarding no
MaxAuthTries 3
AllowTcpForwarding yes
EOF

sshd -t && systemctl restart ssh

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw --force enable

systemctl enable --now fail2ban