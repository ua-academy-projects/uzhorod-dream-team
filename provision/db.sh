#!/usr/bin/env bash
source /tmp/weather-common.sh
: "${USE_REDIS_RABBITMQ:?}" "${POSTGRES_PASSWORD:?}" "${FETCHER_DB_PASSWORD:?}" "${REDIS_PASSWORD:?}" "${RABBITMQ_PASSWORD:?}"
: "${HISTORY_IP:?}" "${FETCHER_IP:?}" "${LOGPULL_PUBKEY:?}" "${LOG_RETENTION_DAYS:?}"
: "${DB_IP:?}" "${POSTGRES_PORT:?}" "${REDIS_PORT:?}" "${RABBITMQ_PORT:?}" "${RABBITMQ_UI_PORT:?}"
POSTGRES_DB=${POSTGRES_DB:-weather}
base_setup
install_docker
setup_journald
setup_log_export

write_env postgres <<ENVF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB}
ENVF
write_conf pg_hba.conf 0644 <<CONF
local all all trust
host all postgres ${HISTORY_IP}/32 scram-sha-256
host ${POSTGRES_DB} fetcher ${FETCHER_IP}/32 scram-sha-256
CONF

write_env redis <<ENVF
REDISCLI_AUTH=${REDIS_PASSWORD}
ENVF
write_conf redis.conf 0640 999 <<CONF
bind 0.0.0.0
port 6379
protected-mode yes
requirepass ${REDIS_PASSWORD}
dir /data
appendonly yes
maxmemory 64mb
maxmemory-policy volatile-lru
CONF

write_env rabbitmq <<ENVF
RABBITMQ_DEFAULT_USER=weather
RABBITMQ_DEFAULT_PASS=${RABBITMQ_PASSWORD}
RABBITMQ_DEFAULT_VHOST=weather
RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS=+S 1:1 +sbwt none +sbwtdcpu none +sbwtdio none
ENVF
write_conf rabbitmq/20-weather.conf 0644 <<CONF
vm_memory_high_watermark.absolute = 256MiB
CONF
write_conf rabbitmq/enabled_plugins 0644 <<CONF
[rabbitmq_management,rabbitmq_tracing].
CONF
write_conf rabbitmq/advanced.config 0640 100 <<CONF
[{rabbitmq_tracing, [{username, <<"weather">>}, {password, <<"${RABBITMQ_PASSWORD}">>}]}].
CONF

write_conf sql/pgmq-setup.sql 0640 <<SQL
\o /dev/null
SELECT 'CREATE ROLE fetcher' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'fetcher')\gexec
ALTER ROLE fetcher WITH LOGIN PASSWORD '${FETCHER_DB_PASSWORD}';
CREATE EXTENSION IF NOT EXISTS pgmq;
SELECT pgmq.create('weather_fetch_requests');
SELECT pgmq.create('weather_fetch_replies');
REVOKE ALL ON SCHEMA public FROM fetcher;
GRANT CONNECT ON DATABASE "${POSTGRES_DB}" TO fetcher;
GRANT USAGE ON SCHEMA pgmq TO fetcher;
GRANT SELECT, INSERT, UPDATE, DELETE ON pgmq.q_weather_fetch_requests, pgmq.q_weather_fetch_replies TO fetcher;
SQL
write_conf sql/pgmq-cleanup.sql 0640 <<'SQL'
DROP EXTENSION IF EXISTS pg_cron CASCADE;
DROP EXTENSION IF EXISTS pgmq CASCADE;
-- the queue tables come from pgmq.create(), not from the extension, so DROP EXTENSION leaves them
DROP SCHEMA IF EXISTS pgmq, cron CASCADE;
DROP TABLE IF EXISTS cache_entries;
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'fetcher') THEN
    DROP OWNED BY fetcher;
    DROP ROLE fetcher;
  END IF;
END
$$;
SQL

postgres_args=(-p "$DB_IP:$POSTGRES_PORT:5432" -v pgdata:/var/lib/postgresql/data
  -v "$ENV_DIR/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro"
  --shm-size 128m --memory 320m --security-opt no-new-privileges
  --health-cmd 'pg_isready -U postgres' --health-interval 10s)
postgres_flags=(-c hba_file=/etc/postgresql/pg_hba.conf
  -c shared_buffers=64MB -c effective_cache_size=192MB -c max_connections=30)
save_run postgres-plain "${postgres_args[@]}" postgres:16-alpine postgres "${postgres_flags[@]}"
save_run postgres-pgmq "${postgres_args[@]}" weather/postgres postgres "${postgres_flags[@]}" \
  -c shared_preload_libraries=pg_cron -c "cron.database_name=$POSTGRES_DB" -c cron.host=/var/run/postgresql

save_run redis \
  -p "$DB_IP:$REDIS_PORT:6379" -v redisdata:/data \
  -v "$ENV_DIR/redis.conf:/usr/local/etc/redis/redis.conf:ro" \
  --user redis --read-only --cap-drop ALL --security-opt no-new-privileges --memory 96m \
  --health-cmd 'redis-cli ping' --health-interval 10s \
  redis:7-alpine redis-server /usr/local/etc/redis/redis.conf

save_run rabbitmq --hostname rabbitmq \
  -p "$DB_IP:$RABBITMQ_PORT:5672" -p "$DB_IP:$RABBITMQ_UI_PORT:15672" -v rabbitmqdata:/var/lib/rabbitmq \
  -v "$ENV_DIR/rabbitmq/20-weather.conf:/etc/rabbitmq/conf.d/20-weather.conf:ro" \
  -v "$ENV_DIR/rabbitmq/enabled_plugins:/etc/rabbitmq/enabled_plugins:ro" \
  -v "$ENV_DIR/rabbitmq/advanced.config:/etc/rabbitmq/advanced.config:ro" \
  --memory 384m --security-opt no-new-privileges \
  --health-cmd 'rabbitmq-diagnostics -q ping' --health-interval 30s \
  rabbitmq:4.1-management-alpine

install -m 0755 /dev/stdin /usr/local/bin/redis-cli <<'SH'
#!/bin/sh
if [ "$(docker inspect -f '{{.State.Running}}' redis 2>/dev/null)" != true ]; then
  echo "the redis container is not running (weather-backend false?)" >&2
  exit 1
fi
if [ -t 0 ]; then tty=-it; else tty=-i; fi
exec docker exec $tty redis redis-cli "$@"
SH

# weather-backend reuses the helpers (ENV_DIR, build_image, start_saved, wait_healthy, psql_as_postgres)
install -D -m 0644 /tmp/weather-common.sh /usr/local/lib/weather/common.sh
install -m 0755 /dev/stdin /usr/local/bin/weather-backend <<SH
#!/usr/bin/env bash
source /usr/local/lib/weather/common.sh
db=${POSTGRES_DB}
SH
cat >> /usr/local/bin/weather-backend <<'SH'

show() {
  echo "backend: $(cat "$ENV_DIR/backend" 2>/dev/null || echo unknown) (true: Redis + RabbitMQ + plain PostgreSQL, false: PostgreSQL + pgmq + pg_cron)"
  docker ps -a --filter name='^(postgres|redis|rabbitmq)$' --format '{{.Names}}: {{.Image}}, {{.Status}}'
}

arg=${1:-}
case "${arg,,}" in
  "") show; exit 0 ;;
  true | 1 | yes) value=true ;;
  false | 0 | no) value=false ;;
  *) echo "usage: weather-backend [true|false]   (true: Redis + RabbitMQ, false: PostgreSQL)" >&2; exit 2 ;;
esac
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
prev=$(cat "$ENV_DIR/backend" 2>/dev/null || echo unknown)

if [ "$value" = true ]; then
  start_saved postgres postgres-plain
  # pgmq and pg_cron can only be left over from false (or an interrupted switch)
  if [ "$prev" != true ]; then
    wait_healthy postgres
    psql_as_postgres "$db" < "$ENV_DIR/sql/pgmq-cleanup.sql"
    echo "PostgreSQL: pgmq, pg_cron, cache_entries and the role fetcher removed"
  fi
  start_saved redis redis
  start_saved rabbitmq rabbitmq
else
  docker rm -f redis rabbitmq >/dev/null 2>&1 || true
  echo "removed containers redis and rabbitmq (their volumes stay)"
  docker image inspect weather/postgres >/dev/null 2>&1 || build_image postgres
  start_saved postgres postgres-pgmq
  wait_healthy postgres
  psql_as_postgres postgres <<<"SELECT 'CREATE DATABASE \"$db\"' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db')\gexec"
  psql_as_postgres "$db" < "$ENV_DIR/sql/pgmq-setup.sql"
  echo "PostgreSQL: role fetcher and the pgmq queues are ready"
fi
echo "$value" > "$ENV_DIR/backend"
show
SH

# Provisioning rebuilds the pgmq image only in false mode, so Dockerfile changes are picked up (cached when unchanged)
if [ "$USE_REDIS_RABBITMQ" = false ]; then
  build_image postgres
fi
weather-backend "$USE_REDIS_RABBITMQ"
