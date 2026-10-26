#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

(( EUID == 0 )) || fail "Run this script with sudo."
: "${PRIVATE_IP:?Set PRIVATE_IP in /etc/kyiv-air/deployment.env or the environment.}"

require_env cloudflare
: "${CERTBOT_EMAIL:?Set CERTBOT_EMAIL in deployment.env for the certificate account.}"
CERTBOT_DOMAIN=${CERTBOT_DOMAIN:-${UI_ORIGIN:-}}
CERTBOT_DOMAIN=${CERTBOT_DOMAIN#https://}
[[ "$CERTBOT_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$CERTBOT_DOMAIN" == *.* ]] ||
  fail "Set CERTBOT_DOMAIN to the public DNS hostname, without a protocol or path."
[[ -s "$ENV_DIR/cloudflare.ini" ]] || fail "Missing $ENV_DIR/cloudflare.ini containing dns_cloudflare_api_token."

install_docker
ensure_network

apt-get install -y --no-install-recommends cron util-linux
readonly CERTIFICATE_GROUP=kyiv-air-certificates
getent group "$CERTIFICATE_GROUP" >/dev/null || groupadd --system "$CERTIFICATE_GROUP"
CERTIFICATE_GID=$(getent group "$CERTIFICATE_GROUP" | cut -d: -f3)
if [[ ! "$ENV_DIR/cloudflare.ini" -ef "$CONFIG/cloudflare.ini" ]]; then
  install -m 0600 "$ENV_DIR/cloudflare.ini" "$CONFIG/cloudflare.ini"
fi
chmod 0600 "$CONFIG/cloudflare.ini"
install -d -m 0700 /etc/letsencrypt /var/lib/letsencrypt
install -d -m 0750 /var/log/letsencrypt
printf 'CERTBOT_IMAGE=%q\nCERTBOT_DOMAIN=%q\nCERTIFICATE_GROUP=%q\n' \
  "$CERTBOT_IMAGE" "$CERTBOT_DOMAIN" "$CERTIFICATE_GROUP" > "$CONFIG/certbot-settings.env"
chmod 0600 "$CONFIG/certbot-settings.env"
install -m 0755 "$HELPERS/renew-certificates.sh" "$APP/bin/renew-certificates"
docker pull "$CERTBOT_IMAGE"
CONFIG="$CONFIG" "$APP/bin/renew-certificates" certonly \
  --dns-cloudflare --agree-tos --email "$CERTBOT_EMAIL" \
  --cert-name "$CERTBOT_DOMAIN" -d "$CERTBOT_DOMAIN" --keep-until-expiring

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
printf 'UI_URL=http://%s:80\nCERTBOT_DOMAIN=%s\n' "$UI_IP" "$CERTBOT_DOMAIN" > "$CONFIG/bastion.env"
chmod 0600 "$CONFIG/bastion.env"
docker pull "$BASTION_IMAGE"
docker run --rm --network "$NETWORK" --env-file "$CONFIG/bastion.env" \
  --group-add "$CERTIFICATE_GID" \
  -v /etc/letsencrypt:/etc/letsencrypt:ro \
  -v "$CONFIG/bastion.conf.template:/etc/nginx/templates/default.conf.template:ro" \
  "$BASTION_IMAGE" nginx -t
wait_command "UI VM (complete UI provisioning before bastion)" \
  curl -fsS --connect-timeout 2 --max-time 3 "http://$UI_IP/"
replace_container kyiv-air-bastion -p "$PRIVATE_IP:80:8080" -p 127.0.0.1:80:8080 \
  -p "$PRIVATE_IP:443:8443" -p 127.0.0.1:443:8443 \
  --group-add "$CERTIFICATE_GID" \
  -v /etc/letsencrypt:/etc/letsencrypt:ro \
  --env-file "$CONFIG/bastion.env" \
  -v "$CONFIG/bastion.conf.template:/etc/nginx/templates/default.conf.template:ro" "$BASTION_IMAGE"
wait_http "http://$PRIVATE_IP/"
wait_command "bastion HTTPS" curl -fsS --connect-timeout 2 --max-time 3 \
  --noproxy '*' --resolve "$CERTBOT_DOMAIN:443:$PRIVATE_IP" "https://$CERTBOT_DOMAIN/"
wait_command "bastion session API over HTTPS" curl -fsS --connect-timeout 2 --max-time 3 \
  --noproxy '*' --resolve "$CERTBOT_DOMAIN:443:$PRIVATE_IP" "https://$CERTBOT_DOMAIN/api/v1/session"

printf '42 8,20 * * * root CONFIG=%q /bin/bash %q >> /var/log/letsencrypt/renewal-cron.log 2>&1\n' \
  "$CONFIG" "$APP/bin/renew-certificates" > /etc/cron.d/kyiv-air-certbot
chmod 0644 /etc/cron.d/kyiv-air-certbot
systemctl enable --now cron

# Cloudflare Tunnel Setup
CLOUDFLARE_TOKEN=$(env_value "$ENV_DIR/cloudflare.env" CLOUDFLARE_TUNNEL_TOKEN)

replace_container cloudflare cloudflare/cloudflared:latest tunnel --no-autoupdate run --token "$CLOUDFLARE_TOKEN"
