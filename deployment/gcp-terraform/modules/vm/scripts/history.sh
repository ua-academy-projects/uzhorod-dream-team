#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

(( EUID == 0 )) || fail "Run this script with sudo."
: "${PRIVATE_IP:?Set PRIVATE_IP in the startup environment.}"

migrate_database() {
  local password
  password=$(get_secret postgres-migration-password)
  validate_password POSTGRES_MIGRATION_PASSWORD "$password" 32
  export GOOSE_DBSTRING="postgres://kyiv_air_migrate:${password}@${DB_HOST}:5432/${POSTGRES_DB}?sslmode=disable"
  export HISTORY_DB_PASSWORD
  HISTORY_DB_PASSWORD=$(get_secret postgres-history-password)
  local env_args=(-e GOOSE_DBSTRING -e HISTORY_DB_PASSWORD -e POSTGRES_ONLY)
  if [[ "$POSTGRES_ONLY" == true ]]; then
    export FETCHER_DB_PASSWORD
    FETCHER_DB_PASSWORD=$(get_secret postgres-fetcher-password)
    env_args+=(-e FETCHER_DB_PASSWORD)
  fi
  docker pull "$POSTGRES_CLIENT_IMAGE"
  wait_command PostgreSQL docker run --rm --network "$NETWORK" "${env_args[@]}" \
    -e PGCONNECT_TIMEOUT=3 "$POSTGRES_CLIENT_IMAGE" sh -c 'psql "$GOOSE_DBSTRING" -v ON_ERROR_STOP=1 -c "SELECT 1"'
  pull_image "$MIGRATION_IMAGE"
  docker run --rm --name kyiv-air-migrate --network "$NETWORK" "${env_args[@]}" "$MIGRATION_IMAGE" up
  unset GOOSE_DBSTRING HISTORY_DB_PASSWORD FETCHER_DB_PASSWORD password
}

prepare_runtime history
if [[ "$CLOUD_SQL" == true ]]; then
  source "$HELPERS/cloud-sql.sh"
  start_sql_proxy
fi
migrate_database
read_database
if [[ "$POSTGRES_ONLY" == false ]]; then read_rabbitmq; fi
pull_image "$HISTORY_IMAGE"
docker pull "$POSTGRES_CLIENT_IMAGE"

set_env history PORT 8081
set_env history POSTGRES_ONLY "$POSTGRES_ONLY"
set_env history DATABASE_URL "$DATABASE_URL"
set_env history FETCHER_SERVICE_URL "http://$FETCHER_IP:8080"
allowed_origins=${ALLOWED_ORIGINS:-}
case ",$allowed_origins," in
  *",$UI_ORIGIN,"*) ;;
  *) allowed_origins="${allowed_origins:+$allowed_origins,}$UI_ORIGIN" ;;
esac
set_env history ALLOWED_ORIGINS "$allowed_origins"
probe=(docker run --rm --network "$NETWORK" --env-file "$CONFIG/history.env")
wait_command PostgreSQL "${probe[@]}" -e PGCONNECT_TIMEOUT=3 --entrypoint sh "$POSTGRES_CLIENT_IMAGE" -c \
  'psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "SELECT id FROM sessions LIMIT 0"'

if [[ "$POSTGRES_ONLY" == false ]]; then
  docker pull "$REDIS_IMAGE"
  set_env history REDIS_URL "$REDIS_URL"
  set_env history RABBITMQ_URL "$RABBITMQ_URL"
  printf 'REDISCLI_AUTH=%s\n' "$REDIS_PASSWORD" > "$CONFIG/redis-probe.env"
  chmod 0600 "$CONFIG/redis-probe.env"
  wait_tcp "$RABBITMQ_HOST" 5672
  wait_command Redis "${probe[@]}" --env-file "$CONFIG/redis-probe.env" -e "REDIS_HOST=$REDIS_HOST" "$REDIS_IMAGE" sh -c \
    '[ "$(redis-cli -h "$REDIS_HOST" PING)" = PONG ]'
else
  sed -i '/^REDIS_URL=/d; /^RABBITMQ_URL=/d' "$CONFIG/history.env"
  rm -f "$CONFIG/redis-probe.env"
fi

start_backend history "$HISTORY_IMAGE" 8081
wait_http http://127.0.0.1:8081/api/v1/locations
wait_http http://127.0.0.1:8081/api/v1/session
