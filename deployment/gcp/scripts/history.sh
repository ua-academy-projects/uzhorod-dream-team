#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

(( EUID == 0 )) || fail "Run this script with sudo."
: "${PRIVATE_IP:?Set PRIVATE_IP in /etc/kyiv-air/deployment.env or the environment.}"

require_env history
read_database
if [[ "$POSTGRES_ONLY" == false ]]; then read_rabbitmq; fi
install_docker
load_image history "$HISTORY_IMAGE"
docker pull "$POSTGRES_CLIENT_IMAGE"
ensure_network

copy_env history
set_env history PORT 8081
set_env history POSTGRES_ONLY "$POSTGRES_ONLY"
set_env history DATABASE_URL "$DATABASE_URL"
set_env history FETCHER_SERVICE_URL "http://$FETCHER_IP:8080"
allowed_origins=$(env_value "$CONFIG/history.env" ALLOWED_ORIGINS)
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
