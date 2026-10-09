#!/usr/bin/env bash
# Fetcher machine: the Go service that talks to CoinGecko.
set -euo pipefail

. /home/vagrant/app/vagrant/lib.sh

# Credentials come from the environment — the Vagrantfile generates them once
# and keeps them outside the repository.
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be provided by the provisioner}"
: "${REDIS_PASSWORD:?REDIS_PASSWORD must be provided by the provisioner}"

cd /home/vagrant/app

REDIS_IP="${REDIS_IP:-127.0.0.1}"

if [ ! -f .env ]; then
  echo "==> writing .env (redis at ${REDIS_IP})"
  sed -e "s/change_me_locally/${POSTGRES_PASSWORD}/g" \
      -e "s/change_me_redis/${REDIS_PASSWORD}/" \
      -e "s#^REDIS_URL=.*#REDIS_URL=redis://${REDIS_IP}:6379#" .env.example > .env
  # Reachable from the other machines rather than from this one only.
  echo "FETCHER_HOST=0.0.0.0" >> .env
  chmod 600 .env
fi

wait_port "$REDIS_IP" 6379

echo "==> image"
sudo docker build -t crypto/fetcher:latest services/fetcher

echo "==> container"
replace crypto_fetcher \
  --hostname fetcher --read-only \
  --env-file .env -e FETCHER_HOST=0.0.0.0 -p 3002:3002 \
  crypto/fetcher:latest
wait_healthy crypto_fetcher
sudo docker image prune -f >/dev/null