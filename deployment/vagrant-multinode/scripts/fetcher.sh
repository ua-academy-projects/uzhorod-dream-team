#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed 's/\r$//' /tmp/kyiv-air-common.sh)

require_env fetcher
key=$(env_value /tmp/kyiv-air-fetcher.env OPENAQ_API_KEY)
[[ "$key" =~ ^[A-Za-z0-9_-]+$ && "$key" != your_openaq_api_key_here ]] || fail "Set an actual OPENAQ_API_KEY in env/fetcher.env."
if [[ "$POSTGRES_ONLY" == true ]]; then read_queue; else read_rabbitmq; fi
install_docker
build_image fetcher "$FETCHER_IMAGE"
configure_firewall
ensure_network

copy_env fetcher
set_env fetcher PORT 8080
set_env fetcher POSTGRES_ONLY "$POSTGRES_ONLY"
if [[ "$POSTGRES_ONLY" == true ]]; then
  set_env fetcher DATABASE_URL "$FETCHER_DATABASE_URL"
  sed -i '/^RABBITMQ_URL=/d' "$CONFIG/fetcher.env"
  docker pull "$POSTGRES_IMAGE"
  wait_command "PostgreSQL queue" docker run --rm --network "$NETWORK" --env-file "$CONFIG/fetcher.env" \
    -e PGCONNECT_TIMEOUT=3 --entrypoint sh "$POSTGRES_IMAGE" -c \
    'psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "SELECT id FROM sync_queue.requests LIMIT 0"'
else
  sed -i '/^DATABASE_URL=/d' "$CONFIG/fetcher.env"
  set_env fetcher RABBITMQ_URL "$RABBITMQ_URL"
  wait_tcp "$RABBITMQ_HOST" 5672
fi
start_backend fetcher "$FETCHER_IMAGE" 8080
