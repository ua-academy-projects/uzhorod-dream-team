#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

USER_NAME=jump
HOME_DIR=/home/$USER_NAME
SSHD_CONF=/etc/ssh/sshd_config.d/10-iss.conf

apply_sshd_config() {
  local backup
  backup=$(mktemp)
  if [[ -f $SSHD_CONF ]]; then cp "$SSHD_CONF" "$backup"; fi
  cat > "$SSHD_CONF"
  if ! sshd -t; then
    if [[ -s $backup ]]; then cp "$backup" "$SSHD_CONF"; else rm -f "$SSHD_CONF"; fi
    rm -f "$backup"
    echo "invalid sshd config, previous config restored" >&2
    exit 1
  fi
  rm -f "$backup"
  systemctl reload ssh
}

id "$USER_NAME" >/dev/null 2>&1 \
  || useradd --system --create-home --home-dir "$HOME_DIR" --shell /bin/sh "$USER_NAME"

options="restrict,port-forwarding"
for target in $PERMIT_OPEN; do
  options+=",permitopen=\"$target\""
done
options+=',command="/bin/false"'

install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$HOME_DIR/.ssh"
printf '%s %s\n' "$options" "$SSH_PUBLIC_KEY" > "$HOME_DIR/.ssh/authorized_keys"
chown "$USER_NAME:$USER_NAME" "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"

apply_sshd_config <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
MaxAuthTries 3
LoginGraceTime 20
AllowAgentForwarding no
AllowTcpForwarding local
AllowStreamLocalForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
AllowUsers $USER_NAME vagrant@$VAGRANT_NAT_IP logreader@$COLLECTOR_IP
EOF

if ! dpkg -s fail2ban >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq fail2ban >/dev/null
fi

cat > /etc/fail2ban/fail2ban.d/iss.local <<'EOF'
[Definition]
logtarget = SYSLOG
EOF

cat > /etc/fail2ban/jail.d/iss.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 $TRUSTED_IP
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF

systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
