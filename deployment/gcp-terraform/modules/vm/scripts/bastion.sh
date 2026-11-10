#!/usr/bin/env bash
set -Eeuo pipefail

: "${SSH_PORT:?Set SSH_PORT in the startup environment.}"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || { echo "Invalid SSH_PORT" >&2; exit 1; }

fail() { echo "$*" >&2; exit 1; }

configure_ssh() {
  install -d -m 0755 /etc/ssh/sshd_config.d
  sed -i -E '/^[[:space:]]*Port[[:space:]]+/d' /etc/ssh/sshd_config
  local snippet
  for snippet in /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$snippet" ]] || continue
    sed -i -E '/^[[:space:]]*Port[[:space:]]+/d' "$snippet"
  done
  printf 'Port %s\n' "$SSH_PORT" > /etc/ssh/sshd_config.d/00-kyiv-air-port.conf
  chmod 0644 /etc/ssh/sshd_config.d/00-kyiv-air-port.conf
  /usr/sbin/sshd -t
  systemctl daemon-reload
  if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
    systemctl restart ssh.socket
  fi
  systemctl restart ssh.service
}

(( EUID == 0 )) || fail "Run this script with sudo."

: "${PRIVATE_IP:?Set PRIVATE_IP in the startup environment.}"
DB_IP=${DB_IP:-}
BASTION_SSH=${BASTION_SSH:-false}
[[ "$BASTION_SSH" == true || "$BASTION_SSH" == false ]] || fail "Invalid BASTION_SSH"
: "${FETCHER_IP:?Set FETCHER_IP in the startup environment.}"
: "${HISTORY_IP:?Set HISTORY_IP in the startup environment.}"
: "${UI_IP:?Set UI_IP in the startup environment.}"

sed -i '/^# BEGIN KYIV-AIR SSH TARGETS$/,/^# END KYIV-AIR SSH TARGETS$/d' /etc/hosts
cat >> /etc/hosts <<HOSTS
# BEGIN KYIV-AIR SSH TARGETS
${DB_IP:+$DB_IP kyiv-air-db}
$FETCHER_IP kyiv-air-fetcher
$HISTORY_IP kyiv-air-history
$UI_IP kyiv-air-ui
# END KYIV-AIR SSH TARGETS
HOSTS

targets=(kyiv-air-fetcher "$FETCHER_IP" kyiv-air-history "$HISTORY_IP" kyiv-air-ui "$UI_IP")
[[ -z "$DB_IP" ]] || targets+=(kyiv-air-db "$DB_IP")
permit_open=
for target in "${targets[@]}"; do permit_open+="$target:22 "; done

cat > /etc/ssh/sshd_config.d/00-kyiv-air-bastion.conf <<SSH
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowAgentForwarding no
X11Forwarding no
AllowTcpForwarding local
PermitOpen ${permit_open% }
PermitTunnel no
GatewayPorts no
SSH

chmod 0644 /etc/ssh/sshd_config.d/00-kyiv-air-bastion.conf
sed -i '\|^Include /etc/ssh/kyiv-air-bastion-public.conf$|d' /etc/ssh/sshd_config

if [[ "$BASTION_SSH" == true ]]; then
  rm -f /etc/ssh/kyiv-air-bastion-public.conf
else
  cat > /etc/ssh/kyiv-air-bastion-public.conf <<SSH
Match LocalAddress $PRIVATE_IP
    MaxSessions 0
SSH
  chmod 0644 /etc/ssh/kyiv-air-bastion-public.conf
  printf '\nInclude /etc/ssh/kyiv-air-bastion-public.conf\n' >> /etc/ssh/sshd_config
fi

configure_ssh
