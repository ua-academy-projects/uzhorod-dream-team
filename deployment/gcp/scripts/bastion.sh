#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

(( EUID == 0 )) || fail "Run this script with sudo."
: "${PRIVATE_IP:?Set PRIVATE_IP in /etc/kyiv-air/deployment.env or the environment.}"

require_env cloudflare

install_docker
ensure_network

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
PermitOpen kyiv-air-db:22 kyiv-air-fetcher:22 kyiv-air-history:22 kyiv-air-ui:22
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
/usr/sbin/sshd -t
systemctl reload ssh

install -m 0644 "$HELPERS/../nginx/bastion.conf.template" "$CONFIG/bastion.conf.template"
printf 'UI_URL=http://%s:80\n' "$UI_IP" > "$CONFIG/bastion.env"
chmod 0600 "$CONFIG/bastion.env"
docker pull "$BASTION_IMAGE"
docker run --rm --network "$NETWORK" --env-file "$CONFIG/bastion.env" \
  -v "$CONFIG/bastion.conf.template:/etc/nginx/templates/default.conf.template:ro" \
  "$BASTION_IMAGE" nginx -t
wait_command "UI VM (complete UI provisioning before bastion)" \
  curl -fsS --connect-timeout 2 --max-time 3 "http://$UI_IP/"
replace_container kyiv-air-bastion -p "$PRIVATE_IP:80:8080" -p 127.0.0.1:80:8080 \
  --env-file "$CONFIG/bastion.env" \
  -v "$CONFIG/bastion.conf.template:/etc/nginx/templates/default.conf.template:ro" "$BASTION_IMAGE"
wait_http "http://$PRIVATE_IP/"
wait_http "http://$PRIVATE_IP/api/v1/session"

# Cloudflare Tunnel Setup
CLOUDFLARE_TOKEN=$(env_value "$ENV_DIR/cloudflare.env" CLOUDFLARE_TUNNEL_TOKEN)

replace_container cloudflare cloudflare/cloudflared:latest tunnel --no-autoupdate run --token "$CLOUDFLARE_TOKEN"
