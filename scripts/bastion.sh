#!/bin/bash

set -euo pipefail

source /vagrant/scripts/utils.sh
write_env /etc/bastion.env \
    FRONTEND_HOST \
    FRONTEND_PORT

SSH_CONFIG="/etc/ssh/sshd_config.d/00-bastion.conf"

cat > "$SSH_CONFIG" << EOF
Port 22
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
AuthenticationMethods publickey
KbdInteractiveAuthentication no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

sshd -t
systemctl reload ssh

apt update
apt install -y nginx gettext-base

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw --force enable

set -a
source /etc/bastion.env
set +a

envsubst '${FRONTEND_HOST} ${FRONTEND_PORT}' \
    < /vagrant/configs/nginx/bastion.conf.template \
    > /etc/nginx/sites-available/frontend-proxy

ln -sf /etc/nginx/sites-available/frontend-proxy \
    /etc/nginx/sites-enabled/frontend-proxy

rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable nginx
systemctl start nginx

bash /vagrant/scripts/ssh/setup_ssh.sh bastion
