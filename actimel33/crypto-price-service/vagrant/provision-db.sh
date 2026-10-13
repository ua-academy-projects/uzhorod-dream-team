#!/usr/bin/env bash
# Database node: PostgreSQL (with pgmq) and, for BACKEND=redis, Redis.
set -euo pipefail

. /home/vagrant/app/vagrant/lib.sh
cd /home/vagrant/app

echo "==> postgres image (postgres:17-alpine + pgmq)"
sudo docker build -q -t crypto/postgres:17-pgmq db >/dev/null

echo "==> postgres"
env_file postgres.env POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD
sudo docker volume create pgdata >/dev/null
# -h 127.0.0.1: during first-time init the server listens on the socket only,
# so a socket check would report healthy before the real server is up.
replace crypto_db \
  --env-file postgres.env -p 5432:5432 -v pgdata:/var/lib/postgresql/data \
  --health-cmd 'pg_isready -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' --health-interval 5s \
  crypto/postgres:17-pgmq
wait_healthy crypto_db

echo "==> queue role"
# The fetcher's login for BACKEND=postgres; its grants come with 003_pgmq.sql.
# The password travels on stdin, and a failing statement is not logged with it.
{
  printf "\\set pw '%s'\n" "$QUEUE_WORKER_PASSWORD"
  cat <<'SQL'
SET log_min_error_statement = panic;
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'queue_worker') THEN
        CREATE ROLE queue_worker LOGIN;
    END IF;
END $$;
ALTER ROLE queue_worker PASSWORD :'pw';
SQL
} | sudo docker exec -i crypto_db sh -c 'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

# Either Redis or Postgres for everything, never both. The redisdata volume
# stays, so switching back keeps the old data.
if [ "$BACKEND" = redis ]; then
  echo "==> redis"
  env_file redis.env REDIS_PASSWORD
  sudo docker volume create redisdata >/dev/null
  replace crypto_redis \
    --env-file redis.env -p 6379:6379 -v redisdata:/data \
    --health-cmd 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping | grep -q PONG' --health-interval 5s \
    redis:7-alpine sh -c 'exec redis-server --requirepass "$REDIS_PASSWORD" --appendonly yes'
  wait_healthy crypto_redis
else
  echo "==> redis: not used with BACKEND=postgres"
  sudo docker rm -f crypto_redis >/dev/null 2>&1 || true
fi
sudo docker image prune -f >/dev/null
