#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed 's/\r$//' /tmp/kyiv-air-common.sh)

require_env fetcher
key=$(env_value /tmp/kyiv-air-fetcher.env OPENAQ_API_KEY)
[[ "$key" =~ ^[A-Za-z0-9_-]+$ && "$key" != your_openaq_api_key_here ]] || fail "Set an actual unquoted OPENAQ_API_KEY in env/fetcher.env."
install_go
build_backend
copy_env fetcher
set_env fetcher PORT "$SERVICE_PORT"
install_unit kyiv-air "$APP" "$APP/bin/fetcher"
configure_firewall
start_application
wait_http "http://127.0.0.1:$SERVICE_PORT/health"
