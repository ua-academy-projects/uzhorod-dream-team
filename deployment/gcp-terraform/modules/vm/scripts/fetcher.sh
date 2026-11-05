#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

(( EUID == 0 )) || fail "Run this script with sudo."
: "${PRIVATE_IP:?Set PRIVATE_IP in the startup environment.}"

prepare_runtime fetcher
if [[ "$POSTGRES_ONLY" == true && "$CLOUD_SQL" == true ]]; then
  source "$HELPERS/cloud-sql.sh"
  start_sql_proxy
fi
key=$(get_secret openaq-api-key)
set_env fetcher OPENAQ_API_KEY "$key"
[[ "$key" =~ ^[A-Za-z0-9_-]+$ && "$key" != your_openaq_api_key_here ]] || fail "Set a valid OpenAQ API key in Secret Manager."
if [[ "$POSTGRES_ONLY" == true ]]; then read_queue; else read_rabbitmq; fi
pull_image "$FETCHER_IMAGE"

set_env fetcher PORT 8080
set_env fetcher POSTGRES_ONLY "$POSTGRES_ONLY"
if [[ "$POSTGRES_ONLY" == true ]]; then
  set_env fetcher DATABASE_URL "$FETCHER_DATABASE_URL"
  sed -i '/^RABBITMQ_URL=/d' "$CONFIG/fetcher.env"
  docker pull "$POSTGRES_CLIENT_IMAGE"
  wait_command "PostgreSQL queue" docker run --rm --network "$NETWORK" --env-file "$CONFIG/fetcher.env" \
    -e PGCONNECT_TIMEOUT=3 --entrypoint sh "$POSTGRES_CLIENT_IMAGE" -c \
    'psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "SELECT msg_id FROM pgmq.q_kyiv_air_requests LIMIT 0; SELECT msg_id FROM pgmq.q_kyiv_air_replies LIMIT 0"'
else
  sed -i '/^DATABASE_URL=/d' "$CONFIG/fetcher.env"
  set_env fetcher RABBITMQ_URL "$RABBITMQ_URL"
  wait_tcp "$RABBITMQ_HOST" 5672
fi
start_backend fetcher "$FETCHER_IMAGE" 8080
