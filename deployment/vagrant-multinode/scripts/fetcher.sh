#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed 's/\r$//' /tmp/kyiv-air-common.sh)

require_env fetcher
key=$(env_value /tmp/kyiv-air-fetcher.env OPENAQ_API_KEY)
[[ "$key" =~ ^[A-Za-z0-9_-]+$ && "$key" != your_openaq_api_key_here ]] || fail "Set an actual OPENAQ_API_KEY in env/fetcher.env."
read_rabbitmq
install_docker
build_image fetcher "$FETCHER_IMAGE"
configure_firewall
ensure_network

copy_env fetcher
set_env fetcher PORT 8080
set_env fetcher RABBITMQ_URL "$RABBITMQ_URL"
wait_tcp "$RABBITMQ_HOST" 5672
start_backend fetcher "$FETCHER_IMAGE" 8080
