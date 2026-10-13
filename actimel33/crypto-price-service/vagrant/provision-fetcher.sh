#!/usr/bin/env bash
# Fetcher machine: the Go service that talks to CoinGecko.
set -euo pipefail

. /home/vagrant/app/vagrant/lib.sh
cd /home/vagrant/app

# Reachable from the other machines rather than from this one only.
FETCHER_HOST=0.0.0.0
if [ "$BACKEND" = postgres ]; then
  wait_port "$DB_IP" 5432
  env_file .env BACKEND FETCHER_HOST QUEUE_DATABASE_URL
else
  wait_port "$DB_IP" 6379
  env_file .env BACKEND FETCHER_HOST REDIS_URL REDIS_PASSWORD
fi

echo "==> image"
sudo docker build -t crypto/fetcher:latest services/fetcher

echo "==> container"
replace crypto_fetcher \
  --hostname fetcher --read-only --env-file .env -p 3002:3002 \
  crypto/fetcher:latest
wait_healthy crypto_fetcher
sudo docker image prune -f >/dev/null
