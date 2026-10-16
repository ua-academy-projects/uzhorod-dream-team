#!/usr/bin/env bash
source /home/vagrant/weather-staging/common.sh || exit 1

configure_ssh sshd-services.conf
require_templates postgres-hba.conf rabbitmq.conf

db_ip=${1:?DB IP is required}
history_ip=${2:?History IP is required}
mode=${3:-}
[[ -z "$mode" || "$mode" == import-db ]] || { echo 'Optional mode: import-db'; exit 1; }

load_secrets
umask 077
native_locked=false
cleanup() {
  local status=$?
  rm -f -- "$stage/secrets.env" "$config/backups/native-weather-history.dump.partial"
  if [[ "$native_locked" == true ]]; then
    sudo -u postgres psql -X -v ON_ERROR_STOP=1 -c 'ALTER ROLE weather_app LOGIN;' >/dev/null
  fi
  return "$status"
}
trap cleanup EXIT

check_database_password
check_rabbitmq_url
[[ -n ${REDIS_PASSWORD:-} && ! "$REDIS_PASSWORD" =~ [[:cntrl:]] ]] || { echo 'Set a single-line REDIS_PASSWORD'; exit 1; }
read_broker_settings
if [[ "$mode" == import-db ]]; then
  [[ -s "$stage/weather_history.dump" && -f "$stage/weather_history.count" ]] || { echo 'Dump and count file are required'; exit 1; }
fi
for dump in "$stage/weather_history.dump" "$stage/weather_history.auto.dump"; do
  if [[ -f "$dump" ]]; then chmod 600 "$dump"; fi
done

# Pull before stopping any existing service.
docker pull postgres:18-alpine
docker pull rabbitmq:4.3-alpine
docker pull redis:7.4-alpine

install -d -m 700 "$config/backups"
native_dump=$config/backups/native-weather-history.dump
if [[ -f /var/lib/postgresql/18/main/PG_VERSION && ! -s "$native_dump" ]]; then
  systemctl start postgresql@18-main
  # Prevent new application writes while taking the migration snapshot.
  sudo -u postgres psql -X -v ON_ERROR_STOP=1 -c 'ALTER ROLE weather_app NOLOGIN;' >/dev/null
  native_locked=true
  sudo -u postgres psql -X -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'weather_app';" >/dev/null
  sudo -u postgres /usr/lib/postgresql/18/bin/pg_dump \
    --format=custom --dbname=weather_history > "$native_dump.partial"
  mv -f "$native_dump.partial" "$native_dump"
  systemctl disable --now postgresql@18-main postgresql
  native_locked=false
fi

# Existing native data is kept on disk; only the services are disabled.
for service in rabbitmq-server redis-server; do
  if [[ -f "/lib/systemd/system/$service.service" ]]; then
    systemctl disable --now "$service.service"
  fi
done

if [[ ! -s "$config/postgres-admin.password" ]]; then
  od -An -N24 -tx1 /dev/urandom | tr -d ' \n' > "$config/postgres-admin.password"
fi
chmod 600 "$config/postgres-admin.password"
printf 'POSTGRES_PASSWORD=%s\nWEATHER_DB_PASSWORD=%s\n' \
  "$(cat "$config/postgres-admin.password")" "$WEATHER_DB_PASSWORD" > "$config/postgres.env"
printf 'RABBITMQ_DEFAULT_USER=%s\nRABBITMQ_DEFAULT_PASS=%s\nRABBITMQ_DEFAULT_VHOST=%s\n' \
  "$rabbit_user" "$rabbit_password" "$rabbit_vhost" > "$config/rabbitmq.env"
printf 'REDIS_PASSWORD=%s\n' "$REDIS_PASSWORD" > "$config/redis.env"
chmod 600 "$config/postgres.env" "$config/rabbitmq.env" "$config/redis.env"
install_template postgres-hba.conf "$config/postgres-hba.conf"
install_template rabbitmq.conf "$config/rabbitmq.conf"

for volume in weather-postgres-data weather-rabbitmq-data weather-redis-data; do
  docker volume create "$volume" >/dev/null
done

remove_container weather-postgres
docker run --detach \
  --name weather-postgres \
  --restart unless-stopped \
  --log-driver local --log-opt max-size=10m --log-opt max-file=3 \
  --env-file "$config/postgres.env" \
  --publish "${db_ip}:5432:5432" \
  --mount type=volume,src=weather-postgres-data,dst=/var/lib/postgresql \
  --mount "type=bind,src=$config/postgres-hba.conf,dst=/etc/postgresql/pg_hba.conf,readonly" \
  postgres:18-alpine postgres -c hba_file=/etc/postgresql/pg_hba.conf
wait_for_container weather-postgres pg_isready -h 127.0.0.1 -U postgres

# The application role is not a PostgreSQL superuser; existing passwords stay intact.
docker exec -i weather-postgres sh -c 'exec psql -X -U postgres -v ON_ERROR_STOP=1 -v app_password="$WEATHER_DB_PASSWORD"' <<'SQL'
SELECT format('CREATE ROLE weather_app LOGIN PASSWORD %L', :'app_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'weather_app') \gexec
SELECT 'CREATE DATABASE weather_history OWNER weather_app'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'weather_history') \gexec
SQL
docker exec weather-postgres sh -c 'PGPASSWORD="$WEATHER_DB_PASSWORD" psql -X -h 127.0.0.1 -U weather_app -d weather_history -v ON_ERROR_STOP=1 -c "SELECT 1"' >/dev/null

restore_dump=''
if [[ "$mode" == import-db ]]; then
  restore_dump=$stage/weather_history.dump
elif [[ -s "$native_dump" ]]; then
  restore_dump=$native_dump
elif [[ -s "$stage/weather_history.auto.dump" ]]; then
  restore_dump=$stage/weather_history.auto.dump
fi
objects=$(docker exec weather-postgres psql -X -U postgres -d weather_history -Atqc "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema';")
if [[ "$mode" == import-db && "$objects" != 0 ]]; then
  echo 'Import refused: target database is not empty' >&2
  exit 1
fi
if [[ "$objects" == 0 && -n "$restore_dump" ]]; then
  docker exec -i weather-postgres pg_restore --username=postgres \
    --dbname=weather_history --role=weather_app --no-owner --no-privileges \
    --single-transaction --exit-on-error < "$restore_dump"
  if [[ "$mode" == import-db ]]; then
    expected=$(tr -d '[:space:]' < "$stage/weather_history.count")
    actual=$(docker exec weather-postgres psql -X -U postgres -d weather_history -Atqc 'SELECT count(*) FROM weather_snapshots;')
    [[ "$actual" == "$expected" ]] || { echo 'Snapshot counts do not match'; exit 1; }
  fi
  echo 'PostgreSQL backup restored'
fi
for migration in "$stage"/migrations/*.sql; do
  { echo 'SET ROLE weather_app;'; cat "$migration"; } | \
    docker exec -i weather-postgres psql -X -U postgres -d weather_history \
      -v ON_ERROR_STOP=1 --single-transaction
done

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
