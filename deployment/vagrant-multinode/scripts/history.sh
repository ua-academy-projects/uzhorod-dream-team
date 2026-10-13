#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed 's/\r$//' /tmp/kyiv-air-common.sh)

require_env history
read_database
read_rabbitmq
install_docker
build_image history "$HISTORY_IMAGE" --target runtime
build_image history "$MIGRATION_IMAGE" --target migrate
docker pull "$POSTGRES_IMAGE"
docker pull "$REDIS_IMAGE"
configure_firewall
ensure_network

copy_env history
set_env history PORT 8081
set_env history DATABASE_URL "$DATABASE_URL"
set_env history REDIS_URL "$REDIS_URL"
set_env history RABBITMQ_URL "$RABBITMQ_URL"
set_env history ALLOWED_ORIGINS "$UI_ORIGIN"
printf 'GOOSE_DBSTRING=%s\n' "$DATABASE_URL" > "$CONFIG/migrate.env"
chmod 0600 "$CONFIG/migrate.env"
printf 'REDISCLI_AUTH=%s\n' "$REDIS_PASSWORD" > "$CONFIG/redis-probe.env"
chmod 0600 "$CONFIG/redis-probe.env"

wait_tcp "$RABBITMQ_HOST" 5672
probe=(docker run --rm --network "$NETWORK" --env-file "$CONFIG/history.env" --env-file "$CONFIG/redis-probe.env")
wait_command PostgreSQL "${probe[@]}" -e PGCONNECT_TIMEOUT=3 --entrypoint sh "$POSTGRES_IMAGE" -c \
  'psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "SELECT 1"'
wait_command Redis "${probe[@]}" -e "REDIS_HOST=$REDIS_HOST" "$REDIS_IMAGE" sh -c \
  '[ "$(redis-cli -h "$REDIS_HOST" PING)" = PONG ]'

if docker container inspect kyiv-air-history >/dev/null 2>&1; then docker stop --timeout 30 kyiv-air-history; fi
require_ca_bundle
docker run --rm --name kyiv-air-migrate --network "$NETWORK" --env-file "$CONFIG/migrate.env" \
  --mount type=bind,src=/etc/ssl/certs/ca-certificates.crt,dst=/etc/ssl/certs/ca-certificates.crt,readonly \
  -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt "$MIGRATION_IMAGE" up
start_backend history "$HISTORY_IMAGE" 8081
wait_http http://127.0.0.1:8081/api/v1/locations
wait_http http://127.0.0.1:8081/api/v1/session
