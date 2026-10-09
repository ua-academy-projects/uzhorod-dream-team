#!/usr/bin/env bash
set -euo pipefail

. /home/vagrant/app/vagrant/lib.sh

# Credentials come from the environment — the Vagrantfile generates them once
# and keeps them outside the repository.
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be provided by the provisioner}"
: "${REDIS_PASSWORD:?REDIS_PASSWORD must be provided by the provisioner}"

cd /home/vagrant/app

if [ ! -f .env ]; then
  echo "==> writing .env"
  sed -e "s/change_me_locally/${POSTGRES_PASSWORD}/g" \
      -e "s/change_me_redis/${REDIS_PASSWORD}/" .env.example > .env
  chmod 600 .env
fi

echo "==> postgres"
sudo docker volume create pgdata >/dev/null
replace crypto_db \
  --env-file .env -p 5432:5432 -v pgdata:/var/lib/postgresql/data \
  --health-cmd 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' --health-interval 5s \
  postgres:17-alpine
wait_healthy crypto_db

echo "==> redis"
sudo docker volume create redisdata >/dev/null
replace crypto_redis \
  -e REDIS_PASSWORD="$REDIS_PASSWORD" -p 6379:6379 -v redisdata:/data \
  --health-cmd 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping | grep -q PONG' --health-interval 5s \
  redis:7-alpine sh -c 'exec redis-server --requirepass "$REDIS_PASSWORD" --appendonly yes'
wait_healthy crypto_redis
