#!/usr/bin/env bash
source /tmp/weather-common.sh
: "${HISTORY_IP:?}" "${HISTORY_PORT:?}" "${FRONTEND_PORT:?}"
: "${LOGPULL_PUBKEY:?}" "${LOG_RETENTION_DAYS:?}"
base_setup
install_docker
setup_journald
setup_log_export

write_env frontend <<ENVF
HISTORY_URL=http://${HISTORY_IP}:${HISTORY_PORT}
ENVF

build_image frontend
run_container frontend \
  -p "$FRONTEND_PORT:8080" --read-only --tmpfs /tmp \
  --tmpfs /var/cache/nginx:uid=101,gid=101 --tmpfs /etc/nginx/conf.d:uid=101,gid=101 \
  --cap-drop ALL --security-opt no-new-privileges --memory 32m weather/frontend

if [ -z "${CLOUDFLARED_TOKEN:-}" ]; then
  echo "CLOUDFLARED_TOKEN is empty, skipping the Cloudflare Tunnel"
  exit 0
fi
if ! command -v cloudflared >/dev/null; then
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -qq
  apt-get install -y -qq cloudflared
fi
# service install fails if the unit already exists, so only run it on first provision
[ -f /etc/systemd/system/cloudflared.service ] || cloudflared service install "$CLOUDFLARED_TOKEN"
