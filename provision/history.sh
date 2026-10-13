#!/usr/bin/env bash
source /tmp/weather-common.sh
: "${POSTGRES_PASSWORD:?}" "${REDIS_PASSWORD:?}" "${RABBITMQ_PASSWORD:?}" "${DB_IP:?}" "${HISTORY_IP:?}"
: "${HISTORY_PORT:?}" "${POSTGRES_PORT:?}" "${REDIS_PORT:?}" "${RABBITMQ_PORT:?}"
: "${LOGPULL_KEY_B64:?}" "${LOG_SOURCES:?}" "${LOG_RETENTION_DAYS:?}"
base_setup
install_docker
setup_journald
setup_log_pull

write_env history <<ENVF
PORT=${HISTORY_PORT}
DATABASE_URL=postgres://postgres:${POSTGRES_PASSWORD}@${DB_IP}:${POSTGRES_PORT}/${POSTGRES_DB:-weather}
AMQP_URL=amqp://weather:${RABBITMQ_PASSWORD}@${DB_IP}:${RABBITMQ_PORT}/weather
REDIS_URL=redis://:${REDIS_PASSWORD}@${DB_IP}:${REDIS_PORT}
TRIGGER_TOKEN=${TRIGGER_TOKEN:-}
ENVF
write_env scheduler <<ENVF
HISTORY_SERVICE_URL=http://history:${HISTORY_PORT}
CRON_SCHEDULE=${CRON_SCHEDULE:-*/15 * * * *}
TRIGGER_TOKEN=${TRIGGER_TOKEN:-}
ENVF

build_image history
build_image scheduler
ensure_network weather

run_container history --network weather \
  -p "$HISTORY_IP:$HISTORY_PORT:$HISTORY_PORT" --init --read-only --tmpfs /tmp --cap-drop ALL \
  --security-opt no-new-privileges --memory 256m weather/history
run_container scheduler --network weather \
  --init --read-only --cap-drop ALL --security-opt no-new-privileges --memory 64m weather/scheduler
