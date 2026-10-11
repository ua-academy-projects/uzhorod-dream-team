#!/usr/bin/env bash
set -euo pipefail

. /home/vagrant/app/vagrant/lib.sh

# Credentials come from the environment — the Vagrantfile generates them once
# and keeps them outside the repository.
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be provided by the provisioner}"
: "${REDIS_PASSWORD:?REDIS_PASSWORD must be provided by the provisioner}"

cd /home/vagrant/app

HISTORY_IP="${HISTORY_IP:-127.0.0.1}"

if [ ! -f .env ]; then
  echo "==> writing .env (history at ${HISTORY_IP})"
  sed -e "s/change_me_locally/${POSTGRES_PASSWORD}/g" \
      -e "s/change_me_redis/${REDIS_PASSWORD}/" .env.example > .env
  chmod 600 .env
fi

echo "==> image"
sudo docker build -t crypto/ui:latest ui

echo "==> container"
replace crypto_ui \
  -e HISTORY_URL="http://${HISTORY_IP}:3001" -p 5173:8080 \
  crypto/ui:latest
wait_healthy crypto_ui
sudo docker image prune -f >/dev/null
# history builds its image in parallel and may come up minutes later.
wait_port "$HISTORY_IP" 3001

echo "==> end-to-end"
curl -sf --retry 20 --retry-delay 2 --retry-connrefused http://127.0.0.1:5173/api/price/latest
echo