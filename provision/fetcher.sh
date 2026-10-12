#!/usr/bin/env bash
source /tmp/weather-common.sh
: "${RABBITMQ_PASSWORD:?}" "${DB_IP:?}" "${RABBITMQ_PORT:?}"
base_setup
install_docker

write_env fetcher <<ENVF
AMQP_URL=amqp://weather:${RABBITMQ_PASSWORD}@${DB_IP}:${RABBITMQ_PORT}/weather
OPEN_METEO_BASE_URL=https://api.open-meteo.com/v1/forecast
ENVF

build_image fetcher
run_container fetcher \
  --read-only --cap-drop ALL --security-opt no-new-privileges --memory 64m weather/fetcher
