#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed 's/\r$//' /tmp/kyiv-air-common.sh)

install_docker
configure_firewall
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
Match LocalAddress $PUBLIC_IP
    MaxSessions 0
SSH
chmod 0644 /etc/ssh/kyiv-air-bastion-public.conf
sed -i '\|^Include /etc/ssh/kyiv-air-bastion-public.conf$|d' /etc/ssh/sshd_config
printf '\nInclude /etc/ssh/kyiv-air-bastion-public.conf\n' >> /etc/ssh/sshd_config
/usr/sbin/sshd -t
systemctl reload ssh

install -m 0644 /tmp/kyiv-air-bastion.conf.template "$CONFIG/bastion.conf.template"
printf 'UI_URL=http://%s:80\n' "$UI_IP" > "$CONFIG/bastion.env"
chmod 0600 "$CONFIG/bastion.env"
docker pull "$BASTION_IMAGE"
docker run --rm --network "$NETWORK" --env-file "$CONFIG/bastion.env" \
  -v "$CONFIG/bastion.conf.template:/etc/nginx/templates/default.conf.template:ro" \
  "$BASTION_IMAGE" nginx -t
wait_command "UI VM (complete UI provisioning before bastion)" \
  curl -fsS --connect-timeout 2 --max-time 3 "http://$UI_IP/"
replace_container kyiv-air-bastion -p "$PUBLIC_IP:80:8080" -p 127.0.0.1:80:8080 \
  --env-file "$CONFIG/bastion.env" \
  -v "$CONFIG/bastion.conf.template:/etc/nginx/templates/default.conf.template:ro" "$BASTION_IMAGE"
wait_http "http://$PUBLIC_IP/"
wait_http "http://$PUBLIC_IP/api/v1/session"
