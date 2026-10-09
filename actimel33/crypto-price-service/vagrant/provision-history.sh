#!/usr/bin/env bash
# History machine: owns the database, serves the public API.
set -euo pipefail

. /home/vagrant/app/vagrant/lib.sh

# Credentials come from the environment.
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be provided by the provisioner}"
: "${REDIS_PASSWORD:?REDIS_PASSWORD must be provided by the provisioner}"
: "${SESSION_SECRET:?SESSION_SECRET must be provided by the provisioner}"

cd /home/vagrant/app

DB_IP="${DB_IP:-127.0.0.1}"
REDIS_IP="${REDIS_IP:-127.0.0.1}"

if [ ! -f .env ]; then
  echo "==> writing .env (database at ${DB_IP}, redis at ${REDIS_IP})"
  sed -e "s/change_me_locally/${POSTGRES_PASSWORD}/g" \
      -e "s/change_me_redis/${REDIS_PASSWORD}/" \
      -e "s/change_me_session/${SESSION_SECRET}/" \
      -e "s#@localhost:5432#@${DB_IP}:5432#" \
      -e "s#^REDIS_URL=.*#REDIS_URL=redis://${REDIS_IP}:6379#" .env.example > .env
  chmod 600 .env
fi

wait_port "$DB_IP" 5432
wait_port "$REDIS_IP" 6379

echo "==> image"
sudo docker build -t crypto/history:latest -f services/history/Dockerfile .

echo "==> container"
replace crypto_history \
  --hostname history --read-only --init \
  --env-file .env -e HISTORY_HOST=0.0.0.0 -p 3001:3001 \
  crypto/history:latest
wait_healthy crypto_history
sudo docker image prune -f >/dev/null