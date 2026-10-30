#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

(( EUID == 0 )) || fail "Run this script with sudo."
: "${PRIVATE_IP:?Set PRIVATE_IP in the startup environment.}"

HISTORY_URL=${HISTORY_URL:-http://$HISTORY_IP:8081}
prepare_runtime ui
CERTBOT_EMAIL=$(get_secret certbot-email)
: "${CERTBOT_EMAIL:?Set a nonempty email address in the certbot-email secret.}"
CERTBOT_DOMAIN=${CERTBOT_DOMAIN:-${UI_ORIGIN:-}}
CERTBOT_DOMAIN=${CERTBOT_DOMAIN#https://}
[[ "$CERTBOT_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$CERTBOT_DOMAIN" == *.* ]] ||
  fail "Set CERTBOT_DOMAIN to the public DNS hostname, without a protocol or path."
printf 'dns_cloudflare_api_token = %s\n' "$(get_secret cloudflare-dns-token)" > "$CONFIG/cloudflare.ini"
chmod 0600 "$CONFIG/cloudflare.ini"
pull_image "$UI_IMAGE"

apt-get install -y --no-install-recommends cron util-linux
readonly CERTIFICATE_GROUP=kyiv-air-certificates
getent group "$CERTIFICATE_GROUP" >/dev/null || groupadd --system "$CERTIFICATE_GROUP"
CERTIFICATE_GID=$(getent group "$CERTIFICATE_GROUP" | cut -d: -f3)
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

wait_command "History VM at $HISTORY_URL (complete History provisioning before UI)" \
  curl -fsS --connect-timeout 2 --max-time 3 "$HISTORY_URL/health"

set_env ui HISTORY_URL "$HISTORY_URL"
set_env ui CERTBOT_DOMAIN "$CERTBOT_DOMAIN"
install -m 0644 "$HELPERS/../nginx/ui.conf.template" "$CONFIG/ui.conf.template"
docker run --rm --network "$NETWORK" --env-file "$CONFIG/ui.env" \
  --group-add "$CERTIFICATE_GID" \
  -v /etc/letsencrypt:/etc/letsencrypt:ro \
  -v "$CONFIG/ui.conf.template:/etc/nginx/templates/default.conf.template:ro" \
  "$UI_IMAGE" nginx -t
ports=(-p "$PRIVATE_IP:80:8080" -p 127.0.0.1:80:8080
  -p "$PRIVATE_IP:443:8443" -p 127.0.0.1:443:8443)
replace_container kyiv-air-ui "${ports[@]}" --env-file "$CONFIG/ui.env" \
  --group-add "$CERTIFICATE_GID" \
  -v /etc/letsencrypt:/etc/letsencrypt:ro \
  -v "$CONFIG/ui.conf.template:/etc/nginx/templates/default.conf.template:ro" "$UI_IMAGE"
wait_http http://127.0.0.1/
wait_command "UI HTTPS" curl -fsS --connect-timeout 2 --max-time 3 \
  --noproxy '*' --resolve "$CERTBOT_DOMAIN:443:$PRIVATE_IP" "https://$CERTBOT_DOMAIN/"
wait_command "UI session API over HTTPS" curl -fsS --connect-timeout 2 --max-time 3 \
  --noproxy '*' --resolve "$CERTBOT_DOMAIN:443:$PRIVATE_IP" "https://$CERTBOT_DOMAIN/api/v1/session"

printf '42 8,20 * * * root CONFIG=%q /bin/bash %q >> /var/log/letsencrypt/renewal-cron.log 2>&1\n' \
  "$CONFIG" "$APP/bin/renew-certificates" > /etc/cron.d/kyiv-air-certbot
chmod 0644 /etc/cron.d/kyiv-air-certbot
systemctl enable --now cron
