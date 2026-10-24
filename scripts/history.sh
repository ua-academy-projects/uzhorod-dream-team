#!/bin/bash

set -euo pipefail

source /vagrant/scripts/utils.sh
write_env /etc/history.env \
    "HISTORY_HOST=0.0.0.0" \
    HISTORY_PORT \
    POSTGRES_HOST \
    POSTGRES_PORT \
    POSTGRES_USER \
    POSTGRES_PASSWORD \
    POSTGRES_DB \
    REDIS_HOST \
    REDIS_PORT \
    REDIS_PASSWORD \
    RABBITMQ_HOST \
    RABBITMQ_PORT \
    RABBITMQ_USER \
    RABBITMQ_PASSWORD \
    QUEUE_TYPE \
    CACHE_TYPE \
    FETCHER_HOST \
    FETCHER_PORT

source /vagrant/scripts/docker_install.sh
install_docker

cd /vagrant/services/history

docker rm -f history 2>/dev/null || true
docker build -t history:latest .

docker run -d \
    --name history \
    --restart unless-stopped \
    -p "${HISTORY_PORT}:${HISTORY_PORT}" \
    --env-file /etc/history.env \
    history:latest

bash /vagrant/scripts/ssh/setup_ssh.sh history