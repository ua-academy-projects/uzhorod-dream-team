#!/usr/bin/env bash
set -Eeuo pipefail
SOURCE=/opt/kyiv-air/source
HELPERS=$SOURCE/deployment/scripts
source "$HELPERS/docker.sh"
trap cleanup_uploads EXIT
ROLE=single
PRIVATE_IP=127.0.0.1
UI_ORIGIN=http://localhost:5173
DB_HOST=kyiv-air-postgres
REDIS_HOST=kyiv-air-redis
RABBITMQ_HOST=kyiv-air-rabbitmq
HISTORY_URL=http://kyiv-air-history:8081

for component in db fetcher history ui; do require_env "$component"; done
validate_fetcher
DB_NAME=$(env_value /tmp/kyiv-air-db.env POSTGRES_DB)
[[ "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]] || fail "POSTGRES_DB must be a lowercase identifier."
install_docker

password() {
  local file=$CONFIG/$1-password
  if [[ ! -s "$file" ]]; then (umask 077; openssl rand -hex 32 > "$file"); fi
  chmod 0600 "$file"
  cat "$file"
}
DB_PASSWORD=$(password db)
REDIS_PASSWORD=$(password redis)
RABBITMQ_PASSWORD=$(password rabbitmq)
validate_password POSTGRES_PASSWORD "$DB_PASSWORD" 16
validate_password REDIS_PASSWORD "$REDIS_PASSWORD" 32
validate_password RABBITMQ_PASSWORD "$RABBITMQ_PASSWORD" 32
DATABASE_URL="postgres://kyiv_air:${DB_PASSWORD}@${DB_HOST}:5432/${DB_NAME}?sslmode=disable"
REDIS_URL="redis://:${REDIS_PASSWORD}@${REDIS_HOST}:6379/0"
RABBITMQ_URL="amqp://kyiv_air:${RABBITMQ_PASSWORD}@${RABBITMQ_HOST}:5672/kyiv-air"

build_image fetcher "$FETCHER_IMAGE"
build_image history "$HISTORY_IMAGE" --target runtime
build_image history "$MIGRATION_IMAGE" --target migrate
build_image ui "$UI_IMAGE"
configure_firewall
ensure_network
prepare_db_environment
prepare_fetcher_environment
prepare_history_environment
for component in ui history fetcher; do
  if docker container inspect "kyiv-air-$component" >/dev/null 2>&1; then docker stop --timeout 30 "kyiv-air-$component"; fi
done
start_databases
migrate_database
start_backend fetcher "$FETCHER_IMAGE" 8080
start_backend history "$HISTORY_IMAGE" 8081
start_ui
wait_http http://127.0.0.1:8081/api/v1/locations
wait_http http://127.0.0.1:8081/api/v1/session
echo "Application ready at http://localhost:5173."
