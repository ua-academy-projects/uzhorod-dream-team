#!/usr/bin/env bash
source /tmp/weather-common.sh
: "${USE_REDIS_RABBITMQ:?}" "${DB_IP:?}" "${RABBITMQ_PASSWORD:?}" "${RABBITMQ_PORT:?}"
: "${FETCHER_DB_PASSWORD:?}" "${POSTGRES_PORT:?}"
: "${LOGPULL_PUBKEY:?}" "${HISTORY_IP:?}" "${LOG_RETENTION_DAYS:?}"
base_setup
install_docker
setup_journald
setup_log_export

write_env fetcher <<ENVF
USE_REDIS_RABBITMQ=${USE_REDIS_RABBITMQ}
AMQP_URL=amqp://weather:${RABBITMQ_PASSWORD}@${DB_IP}:${RABBITMQ_PORT}/weather
DATABASE_URL=postgres://fetcher:${FETCHER_DB_PASSWORD}@${DB_IP}:${POSTGRES_PORT}/${POSTGRES_DB:-weather}
OPEN_METEO_BASE_URL=https://api.open-meteo.com/v1/forecast
ENVF

build_image fetcher
run_container fetcher \
  --read-only --cap-drop ALL --security-opt no-new-privileges --memory 64m weather/fetcher
install_backend_switch fetcher
