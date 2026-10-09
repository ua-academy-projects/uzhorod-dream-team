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
prepare_history_environment
printf 'REDISCLI_AUTH=%s\n' "$REDIS_PASSWORD" > "$CONFIG/redis-probe.env"
chmod 0600 "$CONFIG/redis-probe.env"
wait_dependencies
if docker container inspect kyiv-air-history >/dev/null 2>&1; then docker stop --timeout 30 kyiv-air-history; fi
migrate_database
start_backend history "$HISTORY_IMAGE" 8081
wait_http http://127.0.0.1:8081/api/v1/locations
wait_http http://127.0.0.1:8081/api/v1/session
