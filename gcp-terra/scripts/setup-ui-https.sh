#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "${SCRIPT_DIR}/../../DataFetcher" && pwd)"
# The renewal timer runs this script without the startup process environment.
ENV_FILE="${ENV_FILE:-${COMPOSE_DIR}/ui/.env}"
COMPOSE_FILE_PATH="${COMPOSE_FILE_PATH:-/var/lib/datamonitor/compose.ui.yaml}"
export NGINX_CONFIG_DIR=/var/lib/datamonitor/nginx
export UI_HTTP_BIND=0.0.0.0:80
export UI_HTTPS_BIND=0.0.0.0:443
export COOKIE_SECURE=true

valid_ipv4() {
  local octet
  local -a octets
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$1"
  for octet in "${octets[@]}"; do
    [[ "$octet" == 0 || "$octet" != 0* ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
}

# Use the address actually attached to this VM; no Terraform self-reference.
PUBLIC_IP="$(curl --fail --silent --show-error --retry 5 --max-time 15 \
  -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)"
# The external-ip metadata endpoint supplies the public address; check its syntax.
if ! valid_ipv4 "$PUBLIC_IP"; then
  echo 'ERROR: GCP metadata did not return a valid IPv4 address.' >&2
  exit 1
fi

compose() {
  docker compose --env-file "${ENV_FILE}" \
    --project-directory "${COMPOSE_DIR}" -f "${COMPOSE_FILE_PATH}" \
    --profile ui "$@"
}

export DEBIAN_FRONTEND=noninteractive
CERTBOT=/opt/datamonitor-certbot/bin/certbot
if [[ ! -x "$CERTBOT" ]]; then
  apt-get update
  apt-get install -y python3-venv
  python3 -m venv /opt/datamonitor-certbot
fi
certbot_supported() {
  local version
  version="$("$CERTBOT" --version 2>/dev/null)" || return 1
  [[ "$version" =~ ^certbot\ ([0-9]+)\.([0-9]+)(\.|$) ]] || return 1
  (( 10#${BASH_REMATCH[1]} > 5 || (10#${BASH_REMATCH[1]} == 5 && 10#${BASH_REMATCH[2]} >= 4) ))
}
if ! certbot_supported; then
  /opt/datamonitor-certbot/bin/pip install 'certbot>=5.4,<6'
fi

install -d -m 755 /var/lib/letsencrypt /etc/letsencrypt "${NGINX_CONFIG_DIR}"

# Start HTTP challenge serving before requesting the first certificate.
# Keep HTTPS on subsequent runs when a certificate already exists.
render_config() {
  local tls="$1" temporary_file
  temporary_file="$(mktemp "${NGINX_CONFIG_DIR}/default.conf.XXXXXX")"
  if ! {
    cat "${COMPOSE_DIR}/nginx/ip-http.conf.template" || exit 1
    if [[ "$tls" == true ]]; then
      printf '\n'
      cat "${COMPOSE_DIR}/nginx/ip-https.conf.template" || exit 1
    fi
  } | sed "s/__PUBLIC_IP__/${PUBLIC_IP}/g" > "$temporary_file"; then
    rm -f "$temporary_file"
    return 1
  fi
  chmod 644 "$temporary_file"
  mv "$temporary_file" "${NGINX_CONFIG_DIR}/default.conf"
}

TLS_READY=false
if [[ -s "/etc/letsencrypt/live/${PUBLIC_IP}/fullchain.pem" && \
      -s "/etc/letsencrypt/live/${PUBLIC_IP}/privkey.pem" ]]; then
  TLS_READY=true
fi
render_config "${TLS_READY}"
if [[ "${BUILD_IMAGES:-false}" == true ]]; then
  compose up -d --build ui nginx
else
  compose up -d --no-build ui nginx
fi
# Ensure a running container picks up the current configuration.
docker exec datamonitor-nginx nginx -t
docker exec datamonitor-nginx nginx -s reload

# Also retry failed initial issuance. IP certificates last only about six days.
cat > /etc/systemd/system/datamonitor-ip-https.service <<UNIT
[Unit]
Description=Obtain or renew Data Monitor IP certificate
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash ${SCRIPT_DIR}/setup-ui-https.sh
TimeoutStartSec=20min
UNIT
cat > /etc/systemd/system/datamonitor-ip-https.timer <<'UNIT'
[Unit]
Description=Check Data Monitor IP certificate every six hours

[Timer]
OnCalendar=*-*-* 00,06,12,18:00:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now datamonitor-ip-https.timer

# No email is required; supply --email instead if account notices are desired.
/opt/datamonitor-certbot/bin/certbot certonly \
  --non-interactive --agree-tos --register-unsafely-without-email \
  --preferred-profile shortlived --preferred-challenges http \
  --webroot --webroot-path /var/lib/letsencrypt \
  --ip-address "${PUBLIC_IP}" --cert-name "${PUBLIC_IP}" \
  --keep-until-expiring

render_config true
docker exec datamonitor-nginx nginx -t
docker exec datamonitor-nginx nginx -s reload
