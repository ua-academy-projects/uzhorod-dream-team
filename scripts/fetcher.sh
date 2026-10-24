#!/bin/bash

set -euo pipefail

source /vagrant/scripts/utils.sh
write_env /etc/fetcher.env \
    "FETCHER_HOST=0.0.0.0" \
    FETCHER_PORT \
    RABBITMQ_HOST \
    RABBITMQ_PORT \
    RABBITMQ_USER \
    RABBITMQ_PASSWORD \
    POSTGRES_HOST \
    POSTGRES_PORT \
    POSTGRES_USER \
    POSTGRES_PASSWORD \
    POSTGRES_DB \
    QUEUE_TYPE

source /vagrant/scripts/docker_install.sh
install_docker

cd /vagrant/services/fetcher

docker rm -f fetcher 2>/dev/null || true
docker build -t fetcher:latest .

docker run -d \
    --name fetcher \
    --restart unless-stopped \
    -p "${FETCHER_PORT}:${FETCHER_PORT}" \
    --env-file /etc/fetcher.env \
    fetcher:latest

bash /vagrant/scripts/ssh/setup_ssh.sh fetcher