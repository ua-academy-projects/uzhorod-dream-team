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
