#!/bin/bash
set -euo pipefail

HOME_DIR=/home/$ADMIN_USER
SSHD_CONF=/etc/ssh/sshd_config.d/10-iss.conf
VAGRANT_AUTH=/home/vagrant/.ssh/authorized_keys

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

id "$ADMIN_USER" >/dev/null 2>&1 \
  || useradd --create-home --home-dir "$HOME_DIR" --shell /bin/bash "$ADMIN_USER"

install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$HOME_DIR/.ssh"
printf '%s\n' "$SSH_PUBLIC_KEY" > "$HOME_DIR/.ssh/authorized_keys"
chown "$ADMIN_USER:$ADMIN_USER" "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"

SUDOERS_TMP=$(mktemp)
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER" > "$SUDOERS_TMP"
visudo -cf "$SUDOERS_TMP" >/dev/null
install -m 440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/iss-admin
rm -f "$SUDOERS_TMP"

if [[ -f $VAGRANT_AUTH ]] && grep -qxF "$SSH_PUBLIC_KEY" "$VAGRANT_AUTH"; then
  grep -vxF "$SSH_PUBLIC_KEY" "$VAGRANT_AUTH" > "$VAGRANT_AUTH.tmp" || true
  cat "$VAGRANT_AUTH.tmp" > "$VAGRANT_AUTH"
  rm -f "$VAGRANT_AUTH.tmp"
fi

apply_sshd_config <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowAgentForwarding no
X11Forwarding no
AllowUsers $ADMIN_USER@$BASTION_IP vagrant@$VAGRANT_NAT_IP logreader@$COLLECTOR_IP
EOF
