#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh"

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

cat > /etc/ssh/sshd_config.d/00-kyiv-air-bastion.conf <<SSH
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowAgentForwarding no
X11Forwarding no
AllowTcpForwarding local
PermitOpen ${DB_IP:+kyiv-air-db:$SSH_PORT }kyiv-air-fetcher:$SSH_PORT kyiv-air-history:$SSH_PORT kyiv-air-ui:$SSH_PORT
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
