#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed 's/\r$//' /tmp/kyiv-air-common.sh)
source <(sed 's/\r$//' /tmp/kyiv-air-rabbitmq.sh)

require_env fetcher
read_rabbitmq
key=$(env_value /tmp/kyiv-air-fetcher.env OPENAQ_API_KEY)
[[ "$key" =~ ^[A-Za-z0-9_-]+$ && "$key" != your_openaq_api_key_here ]] || fail "Set an actual unquoted OPENAQ_API_KEY in env/fetcher.env."
install_go
build_backend
copy_env fetcher
set_env fetcher PORT "$SERVICE_PORT"
set_env fetcher RABBITMQ_URL "$RABBITMQ_URL"
wait_broker
pre_start="ExecStartPre=$APP/bin/wait-ready.sh tcp $DB_IP $RABBITMQ_PORT $READY_TIMEOUT"
install_unit kyiv-air "$APP" "$APP/bin/fetcher" "$pre_start"
configure_firewall
start_application
wait_http "http://127.0.0.1:$SERVICE_PORT/health"
