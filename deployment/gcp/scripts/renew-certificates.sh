#!/usr/bin/env bash
set -euo pipefail

readonly CONFIG=${CONFIG:-/etc/kyiv-air}
readonly NGINX_CONTAINER=kyiv-air-bastion

(( EUID == 0 )) || { echo "Run this script with sudo." >&2; exit 1; }
source "$CONFIG/certbot-settings.env"
if (( $# == 0 )); then set -- renew; fi
exec 9>/run/lock/kyiv-air-certbot.lock
flock -n 9 || exit 0

docker run --rm \
  -v /etc/letsencrypt:/etc/letsencrypt \
  -v /var/lib/letsencrypt:/var/lib/letsencrypt \
  -v /var/log/letsencrypt:/var/log/letsencrypt \
  -v "$CONFIG/cloudflare.ini:/run/secrets/cloudflare.ini:ro" \
  "$CERTBOT_IMAGE" "$@" \
  --dns-cloudflare-credentials /run/secrets/cloudflare.ini \
  --non-interactive

for directory in /etc/letsencrypt /etc/letsencrypt/live /etc/letsencrypt/archive; do
  chgrp "$CERTIFICATE_GROUP" "$directory"
  chmod 0750 "$directory"
done
for directory in "/etc/letsencrypt/live/$CERTBOT_DOMAIN" "/etc/letsencrypt/archive/$CERTBOT_DOMAIN"; do
  chgrp -hR "$CERTIFICATE_GROUP" "$directory"
  chmod -R g+rX,o-rwx "$directory"
done

if [[ $1 == renew ]]; then
  docker exec "$NGINX_CONTAINER" nginx -t
  docker exec "$NGINX_CONTAINER" nginx -s reload
fi
