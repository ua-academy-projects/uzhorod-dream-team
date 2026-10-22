#!/usr/bin/env bash
# Provisioning of weather-vm, step "db-extensions": PostgreSQL extensions for app_mode postgres.
#   pgmq    - message queues (instead of RabbitMQ);
#   pg_cron - jobs on a schedule inside PostgreSQL (removes expired settings, like the TTL of Redis);
#   hstore  - key/value values (the UI settings, like a value in Redis).
# They are installed in both modes: in mode rabbitmq they are simply not used.
# PostgreSQL is restarted only when the settings of pg_cron change (the first run).
# Runs after provision/db.sh (it installs PostgreSQL). Running it again is safe.
set -euo pipefail

if [[ ! "${WEATHER_DB_NAME:-}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; then
  echo "WEATHER_DB_NAME must be a lowercase PostgreSQL identifier" >&2
  exit 1
fi

# pgmq has no apt package for Ubuntu: the release from GitHub, checked by its SHA-256.
# pgmq is plain SQL (no C code), so its files are only copied, as "make install" does.
PGMQ_VERSION=1.13.0
PGMQ_URL=https://github.com/pgmq/pgmq/archive/refs/tags/v$PGMQ_VERSION.tar.gz
PGMQ_SHA256=c980705ffa2a731b69f3d26be5650d6fbcc76b2b9add67b138da4ee74a4579a5

# Major version of PostgreSQL (16 in Ubuntu 24.04): the names of the package and folders use it.
pg_version=$(pg_lsclusters --no-header | awk 'NR == 1 { print $1 }')
if [[ -z "$pg_version" ]]; then
  echo "PostgreSQL cluster not found" >&2
  exit 1
fi
extension_dir=/usr/share/postgresql/$pg_version/extension

# 1. pg_cron: the package of Ubuntu (universe), built for the same PostgreSQL.
#    hstore needs nothing: it comes with PostgreSQL itself.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y "postgresql-$pg_version-cron"

# 2. pgmq: download only if this version is not installed yet.
if [[ ! -f "$extension_dir/pgmq--$PGMQ_VERSION.sql" ]]; then
  work_dir=$(mktemp -d)
  trap 'rm -rf "$work_dir"' EXIT
  curl --fail --silent --show-error --location --max-time 60 --retry 3 \
    --output "$work_dir/pgmq.tar.gz" "$PGMQ_URL"
  # A different file (damaged or replaced) stops the script here.
  echo "$PGMQ_SHA256  $work_dir/pgmq.tar.gz" | sha256sum --check --quiet
  tar -xzf "$work_dir/pgmq.tar.gz" -C "$work_dir"
  source_dir="$work_dir/pgmq-$PGMQ_VERSION/pgmq-extension"
  # The same files as "make install": control file, the SQL of this version, update scripts.
  install -m 644 "$source_dir/pgmq.control" "$extension_dir/"
  install -m 644 "$source_dir/sql/pgmq.sql" "$extension_dir/pgmq--$PGMQ_VERSION.sql"
  install -m 644 "$source_dir"/sql/pgmq--*--*.sql "$extension_dir/"
fi

# 3. pg_cron must be loaded when PostgreSQL starts (shared_preload_libraries).
#    cron.database_name: the jobs live in the database of the app.
#    cron.use_background_workers: jobs run inside PostgreSQL, without a network login,
#      so pg_hba.conf needs no new line.
config_dir=$(dirname "$(runuser -u postgres -- psql -tAc 'SHOW config_file')")
cron_config="$config_dir/conf.d/pg_cron.conf"
new_config=$(cat <<EOF
shared_preload_libraries = 'pg_cron'
cron.database_name = '$WEATHER_DB_NAME'
cron.use_background_workers = on
EOF
)
if [[ ! -f "$cron_config" || "$(cat "$cron_config")" != "$new_config" ]]; then
  echo "$new_config" > "$cron_config"
  chown postgres:postgres "$cron_config"
  # These settings change only after a restart. History reconnects by itself.
  systemctl restart postgresql
  for _ in $(seq 30); do
    runuser -u postgres -- pg_isready --quiet && break
    sleep 1
  done
fi

# 4. The extensions in the database of the app. UPDATE: a newer installed version is applied.
runuser -u postgres -- psql -d "$WEATHER_DB_NAME" -v ON_ERROR_STOP=1 -q <<'SQL'
-- Without "already installed" notices on a repeated run.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS pgmq;
ALTER EXTENSION pgmq UPDATE;
CREATE EXTENSION IF NOT EXISTS pg_cron;
SQL

runuser -u postgres -- psql -d "$WEATHER_DB_NAME" \
  -c "SELECT extname, extversion FROM pg_extension ORDER BY extname"
