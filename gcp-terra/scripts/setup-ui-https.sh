#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "${SCRIPT_DIR}/../../DataFetcher" && pwd)"
export NGINX_CONFIG_DIR=/var/lib/datamonitor/nginx
export UI_HTTP_BIND=0.0.0.0:80
export UI_HTTPS_BIND=0.0.0.0:443
export COOKIE_SECURE=true

# Use the address actually attached to this VM; no Terraform self-reference.
PUBLIC_IP="$(curl --fail --silent --show-error --retry 5 --max-time 15 \
  -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)"
python3 - "${PUBLIC_IP}" <<'PY'
import ipaddress, sys
if not ipaddress.IPv4Address(sys.argv[1]).is_global:
    raise SystemExit('A public IPv4 address is required for IP HTTPS')
PY

compose() {
  docker compose --env-file "${COMPOSE_DIR}/.env" \
    --project-directory "${COMPOSE_DIR}" -f "${COMPOSE_DIR}/docker-compose.yml" \
    --profile ui "$@"
}

export DEBIAN_FRONTEND=noninteractive
if [[ ! -x /opt/datamonitor-certbot/bin/certbot ]]; then
  apt-get update
  apt-get install -y python3-venv
  python3 -m venv /opt/datamonitor-certbot
fi
if ! /opt/datamonitor-certbot/bin/python -c 'from importlib.metadata import version; assert tuple(map(int,version("certbot").split(".")[:2])) >= (5,4)' 2>/dev/null; then
  /opt/datamonitor-certbot/bin/pip install 'certbot>=5.4,<6'
fi

install -d -m 755 /var/lib/letsencrypt /etc/letsencrypt "${NGINX_CONFIG_DIR}"

# Start HTTP challenge serving before requesting the first certificate.
# Keep HTTPS on subsequent runs when a certificate already exists.
render_config() {
  python3 - "${COMPOSE_DIR}/nginx" "${NGINX_CONFIG_DIR}" "${PUBLIC_IP}" "$1" <<'PY'
from pathlib import Path
import sys
root, output, address, tls = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4] == 'true'
config = (root / 'ip-http.conf.template').read_text()
if tls:
    config += '\n' + (root / 'ip-https.conf.template').read_text()
p = output / 'default.conf'
tmp = p.with_suffix('.tmp')
tmp.write_text(config.replace('__PUBLIC_IP__', address))
tmp.replace(p)
PY
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
