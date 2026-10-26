#!/usr/bin/env bash
set -euo pipefail
umask 077

backend=${1:?backend is required}
db_ip=${2:?DB IP is required}
config=/etc/weather-forecast
migrations=/var/lib/weather-forecast/migrations

remove_container() {
  if docker container inspect "$1" >/dev/null 2>&1; then
    docker stop --time 60 "$1" >/dev/null
    docker rm "$1" >/dev/null
  fi
}

wait_for_container() {
  local name=$1 attempt
  shift
  for attempt in {1..60}; do
    if docker exec "$name" "$@" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  docker logs --tail 30 "$name"
  echo "$name did not become ready" >&2
  return 1
}

if [[ ! -s "$config/postgres-admin.password" ]]; then
  od -An -N24 -tx1 /dev/urandom | tr -d ' \n' > "$config/postgres-admin.password"
fi
chmod 600 "$config/postgres-admin.password"
{
  printf 'POSTGRES_PASSWORD=%s\n' "$(cat "$config/postgres-admin.password")"
  cat "$config/db-app.env"
} > "$config/postgres.env"
chmod 600 "$config/postgres.env"

docker volume create weather-postgres-data >/dev/null
if [[ "$backend" == rabbitmq_redis ]]; then
  for volume in weather-rabbitmq-data weather-redis-data; do
    docker volume create "$volume" >/dev/null
  done
fi

remove_container weather-postgres
docker run --detach \
  --name weather-postgres \
  --restart unless-stopped \
  --log-driver local --log-opt max-size=10m --log-opt max-file=3 \
  --env-file "$config/postgres.env" \
  --publish "${db_ip}:5432:5432" \
  --mount type=volume,src=weather-postgres-data,dst=/var/lib/postgresql \
  --mount "type=bind,src=$config/postgres-hba.conf,dst=/etc/postgresql/pg_hba.conf,readonly" \
  weather-postgres:dev postgres -c hba_file=/etc/postgresql/pg_hba.conf
wait_for_container weather-postgres pg_isready -h 127.0.0.1 -U postgres

docker exec -i weather-postgres sh -c 'exec psql -X -U postgres -v ON_ERROR_STOP=1 -v app_password="$WEATHER_DB_PASSWORD"' <<'SQL'
SELECT format('CREATE ROLE weather_app LOGIN PASSWORD %L', :'app_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'weather_app') \gexec
SELECT 'CREATE DATABASE weather_history OWNER weather_app'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'weather_history') \gexec
SQL
docker exec weather-postgres sh -c 'PGPASSWORD="$WEATHER_DB_PASSWORD" psql -X -h 127.0.0.1 -U weather_app -d weather_history -v ON_ERROR_STOP=1 -c "SELECT 1"' >/dev/null

docker exec -i weather-postgres psql -X -U postgres -d weather_history -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgmq VERSION '1.13.0';
CREATE EXTENSION IF NOT EXISTS hstore WITH SCHEMA public;
SQL

for migration in "$migrations"/*.sql; do
  migration_role=weather_app
  [[ ${migration##*/} != 005_postgres_queue.sql ]] || migration_role=postgres
  { printf 'SET ROLE %s;\n' "$migration_role"; cat "$migration"; } | \
    docker exec -i weather-postgres psql -X -U postgres -d weather_history \
      -v ON_ERROR_STOP=1 --single-transaction
done

docker exec -i weather-postgres psql -X -U postgres -d weather_history -v ON_ERROR_STOP=1 <<'SQL'
GRANT USAGE ON SCHEMA pgmq TO weather_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON pgmq.q_weather_requests, pgmq.q_weather_responses TO weather_app;
GRANT USAGE, SELECT ON SEQUENCE pgmq.q_weather_requests_msg_id_seq, pgmq.q_weather_responses_msg_id_seq TO weather_app;
SQL

if [[ "$backend" == postgres ]]; then
  docker exec -i weather-postgres sh -c 'exec psql -X -U postgres -d weather_history -v ON_ERROR_STOP=1 -v fetcher_password="$WEATHER_FETCHER_DB_PASSWORD"' <<'SQL'
SELECT format('CREATE ROLE weather_fetcher LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L', :'fetcher_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'weather_fetcher') \gexec
GRANT CONNECT ON DATABASE weather_history TO weather_fetcher;
GRANT USAGE ON SCHEMA public TO weather_fetcher;
GRANT USAGE ON SCHEMA pgmq TO weather_fetcher;
GRANT SELECT, UPDATE, DELETE ON pgmq.q_weather_requests TO weather_fetcher;
GRANT INSERT ON pgmq.q_weather_responses TO weather_fetcher;
GRANT SELECT (msg_id) ON pgmq.q_weather_responses TO weather_fetcher;
GRANT USAGE ON SEQUENCE pgmq.q_weather_responses_msg_id_seq TO weather_fetcher;
SQL
  docker exec weather-postgres sh -c 'PGPASSWORD="$WEATHER_FETCHER_DB_PASSWORD" psql -X -h 127.0.0.1 -U weather_fetcher -d weather_history -v ON_ERROR_STOP=1 -c "SELECT msg_id FROM pgmq.q_weather_requests LIMIT 0"' >/dev/null
  for container in weather-rabbitmq weather-redis; do
    if docker container inspect "$container" >/dev/null 2>&1; then
      docker stop --time 60 "$container" >/dev/null
    fi
  done
  echo 'PGMQ queue and hstore preferences cache are ready; RabbitMQ and Redis are not running'
  exit 0
fi

remove_container weather-rabbitmq
docker run --detach \
  --name weather-rabbitmq --hostname weather-rabbitmq \
  --restart unless-stopped \
  --log-driver local --log-opt max-size=10m --log-opt max-file=3 \
  --env-file "$config/rabbitmq.env" \
  --publish "${db_ip}:5672:5672" \
  --mount type=volume,src=weather-rabbitmq-data,dst=/var/lib/rabbitmq \
  --mount "type=bind,src=$config/rabbitmq.conf,dst=/etc/rabbitmq/rabbitmq.conf,readonly" \
  rabbitmq:4.3-alpine
wait_for_container weather-rabbitmq rabbitmq-diagnostics -q check_running
docker exec weather-rabbitmq sh -c 'rabbitmqctl authenticate_user "$RABBITMQ_DEFAULT_USER" "$RABBITMQ_DEFAULT_PASS" >/dev/null 2>&1'
docker exec weather-rabbitmq sh -c 'rabbitmqctl set_permissions -p "$RABBITMQ_DEFAULT_VHOST" "$RABBITMQ_DEFAULT_USER" "$1" "$1" "$1"' \
  sh '^(weather\.requests|weather\.responses|amq\.default)$'

remove_container weather-redis
docker run --detach \
  --name weather-redis \
  --restart unless-stopped \
  --log-driver local --log-opt max-size=10m --log-opt max-file=3 \
  --env-file "$config/redis.env" \
  --publish "${db_ip}:6379:6379" \
  --mount type=volume,src=weather-redis-data,dst=/data \
  redis:7.4-alpine sh -c 'exec /usr/local/bin/docker-entrypoint.sh redis-server --appendonly yes --requirepass "$REDIS_PASSWORD"'
wait_for_container weather-redis sh -c 'test "$(REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --raw PING)" = PONG'
echo 'PostgreSQL, RabbitMQ and Redis containers are ready'
