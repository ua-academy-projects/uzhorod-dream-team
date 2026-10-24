#!/bin/bash

set -euo pipefail

source /vagrant/scripts/utils.sh
write_env /etc/frontend.env \
    "FRONTEND_HOST=0.0.0.0" \
    FRONTEND_PORT \
    HISTORY_HOST \
    HISTORY_PORT \
    POSTGRES_HOST

source /vagrant/scripts/docker_install.sh
install_docker

cd /vagrant/frontend

docker rm -f frontend 2>/dev/null || true
docker build -t frontend:latest .

docker run -d \
    --name frontend \
    --restart unless-stopped \
    -p "${FRONTEND_PORT}:80" \
   --env-file /etc/frontend.env \
    frontend:latest

bash /vagrant/scripts/ssh/setup_ssh.sh frontend