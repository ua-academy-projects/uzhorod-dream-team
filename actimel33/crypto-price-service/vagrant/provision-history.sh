#!/usr/bin/env bash
# History machine: owns the database, serves the public API.
set -euo pipefail

. /home/vagrant/app/vagrant/lib.sh
cd /home/vagrant/app

# Reachable from the UI and Fetcher machines.
HISTORY_HOST=0.0.0.0
wait_port "$DB_IP" 5432
if [ "$BACKEND" = redis ]; then
  wait_port "$DB_IP" 6379
  env_file .env BACKEND HISTORY_HOST DATABASE_URL SESSION_SECRET REDIS_URL REDIS_PASSWORD
else
  env_file .env BACKEND HISTORY_HOST DATABASE_URL SESSION_SECRET
fi

echo "==> image"
sudo docker build -t crypto/history:latest -f services/history/Dockerfile .

echo "==> container"
replace crypto_history \
  --hostname history --read-only --init --env-file .env -p 3001:3001 \
  crypto/history:latest
wait_healthy crypto_history
sudo docker image prune -f >/dev/null
