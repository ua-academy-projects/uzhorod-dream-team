#!/usr/bin/env bash
source /home/vagrant/weather-staging/common.sh || exit 1

configure_ssh
require_templates redis-network.conf rabbitmq.conf

db_ip=${1:?DB IP is required}
history_ip=${2:?History IP is required}
mode=${3:-}
[[ -z "$mode" || "$mode" == import-db ]] || { echo 'Optional mode: import-db'; exit 1; }

load_secrets
check_database_password
check_rabbitmq_url
[[ -n ${REDIS_PASSWORD:-} && ! "$REDIS_PASSWORD" =~ [[:cntrl:]] ]] || { echo 'Set a single-line REDIS_PASSWORD'; exit 1; }
if [[ "$mode" == import-db ]]; then
  [[ -f "$stage/weather_history.dump" && -f "$stage/weather_history.count" ]] || { echo 'Dump and count file are required'; exit 1; }
fi

read_broker_settings
# PostgreSQL packages and private-network access.
install -d /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
echo 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main' > /etc/apt/sources.list.d/pgdg.list
apt-get update
apt-get install -y postgresql-18 postgresql-client-18
# Keep existing broker versions, configuration, credentials, and data.
apt-get install -y --no-upgrade rabbitmq-server redis-server

echo "listen_addresses = '${db_ip},127.0.0.1'" >> /etc/postgresql/18/main/postgresql.conf
sed -i "1i host weather_history weather_app ${history_ip}/32 scram-sha-256" /etc/postgresql/18/main/pg_hba.conf
systemctl enable postgresql
systemctl restart postgresql@18-main

# Create only missing database objects; keep existing credentials and data.
if [[ $(sudo -u postgres psql -X -Atqc "SELECT count(*) FROM pg_roles WHERE rolname='weather_app';") == 0 ]]; then
  sudo -u postgres psql -X -v ON_ERROR_STOP=1 -c "CREATE ROLE weather_app LOGIN PASSWORD '$WEATHER_DB_PASSWORD';"
fi
if [[ $(sudo -u postgres psql -X -Atqc "SELECT count(*) FROM pg_database WHERE datname='weather_history';") == 0 ]]; then
  sudo -u postgres createdb --owner=weather_app weather_history
fi

# Import is explicit and allowed only into an empty database.
if [[ "$mode" == import-db ]]; then
  objects=$(sudo -u postgres psql -X -d weather_history -Atqc "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema';")
  [[ "$objects" == 0 ]] || { echo 'Import refused: target database is not empty'; exit 1; }
  install -m 600 -o postgres -g postgres "$stage/weather_history.dump" /var/lib/postgresql/weather_history.dump
  sudo -u postgres /usr/lib/postgresql/18/bin/pg_restore --dbname=weather_history --role=weather_app --no-owner --no-privileges --single-transaction --exit-on-error /var/lib/postgresql/weather_history.dump
  expected=$(tr -d '[:space:]' < "$stage/weather_history.count")
  actual=$(sudo -u postgres psql -X -d weather_history -Atc 'SELECT count(*) FROM weather_snapshots;')
  [[ "$actual" == "$expected" ]] || { echo "Snapshot counts do not match: Arch=$expected VM=$actual"; exit 1; }
  echo "Imported $actual weather_snapshots rows"
  rm /var/lib/postgresql/weather_history.dump
else
  { echo 'SET ROLE weather_app;'; cat "$stage/migrations/001_create_weather_snapshots.sql"; } | sudo -u postgres psql -X -d weather_history -v ON_ERROR_STOP=1 --single-transaction
fi
for migration in 002_unique_weather_time.sql 003_temperature_history.sql 004_weather_jobs.sql; do
  { echo 'SET ROLE weather_app;'; cat "$stage/migrations/$migration"; } | sudo -u postgres psql -X -d weather_history -v ON_ERROR_STOP=1 --single-transaction
done
echo 'Configuring RabbitMQ and Redis on the DB VM'
configure_redis
configure_rabbitmq
