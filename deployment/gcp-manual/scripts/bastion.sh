#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

(( EUID == 0 )) || fail "Run this script with sudo."
: "${PRIVATE_IP:?Set PRIVATE_IP in /etc/kyiv-air/deployment.env or the environment.}"
: "${DB_IP:?Set DB_IP in deployment.env.}"
: "${FETCHER_IP:?Set FETCHER_IP in deployment.env.}"
: "${HISTORY_IP:?Set HISTORY_IP in deployment.env.}"
: "${UI_IP:?Set UI_IP in deployment.env.}"

sed -i '/^# BEGIN KYIV-AIR SSH TARGETS$/,/^# END KYIV-AIR SSH TARGETS$/d' /etc/hosts
cat >> /etc/hosts <<HOSTS
# BEGIN KYIV-AIR SSH TARGETS
$DB_IP kyiv-air-db
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
PermitOpen kyiv-air-db:$SSH_PORT kyiv-air-fetcher:$SSH_PORT kyiv-air-history:$SSH_PORT kyiv-air-ui:$SSH_PORT
PermitTunnel no
GatewayPorts no
SSH
chmod 0644 /etc/ssh/sshd_config.d/00-kyiv-air-bastion.conf
cat > /etc/ssh/kyiv-air-bastion-public.conf <<SSH
Match LocalAddress $PRIVATE_IP
    MaxSessions 0
SSH
chmod 0644 /etc/ssh/kyiv-air-bastion-public.conf
sed -i '\|^Include /etc/ssh/kyiv-air-bastion-public.conf$|d' /etc/ssh/sshd_config
printf '\nInclude /etc/ssh/kyiv-air-bastion-public.conf\n' >> /etc/ssh/sshd_config
configure_ssh

rm -f /etc/cron.d/kyiv-air-certbot
if command -v docker >/dev/null 2>&1; then
  for container in kyiv-air-bastion cloudflare; do
    if docker container inspect "$container" >/dev/null 2>&1; then
      docker stop --timeout 30 "$container" >/dev/null
      docker rm "$container" >/dev/null
    fi
  done
fi
