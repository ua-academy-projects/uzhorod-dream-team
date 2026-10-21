#!/usr/bin/env bash
# Postgres for the pgmq queue and history. The script is idempotent.
# PG_TARGETS: "user:pass:db:pgmq,..." (each field urlencoded; pgmq=1 marks the queue DB: pgmq + hstore for the fetcher cache).
# The Vagrantfile builds it from PGMQ_URL (deploy/queue.env) and DATABASE_URL (deploy/env/history.env).
set -euo pipefail

PGMQ_VERSION=v1.13.0
PGMQ_SHA256=bf7e66c75ed771df0c5f7cb2b9f0123ca77992daacd56e3911d1894a3efa99de
LISTEN_IP=10.10.0.25
CLIENTS=(10.10.0.21 10.10.0.22) # fetcher, history

urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

# Neither Debian nor PGDG ships a pgmq package for trixie, so it is installed as plain SQL (no extension)
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql curl ca-certificates

PGVER=$(ls /etc/postgresql | sort -n | tail -1)
CONF=/etc/postgresql/$PGVER/main

# listen on the private address and allow only the fetcher and history VMs
cat >"$CONF/conf.d/10-reload.conf" <<EOF
listen_addresses = 'localhost,$LISTEN_IP'
EOF
for c in "${CLIENTS[@]}"; do
  rule="host all all $c/32 scram-sha-256"
  grep -qxF "$rule" "$CONF/pg_hba.conf" || echo "$rule" >>"$CONF/pg_hba.conf"
done
systemctl restart postgresql
systemctl enable postgresql

psql_admin() { sudo -u postgres psql -qtAX -v ON_ERROR_STOP=1 "$@"; }

PGMQ_SQL=$(mktemp)
trap 'rm -f "$PGMQ_SQL"' EXIT
curl -fsSL "https://raw.githubusercontent.com/pgmq/pgmq/$PGMQ_VERSION/pgmq-extension/sql/pgmq.sql" -o "$PGMQ_SQL"
echo "$PGMQ_SHA256  $PGMQ_SQL" | sha256sum -c - >/dev/null
chmod 644 "$PGMQ_SQL"

IFS=',' read -ra targets <<<"${PG_TARGETS:-}"
for t in "${targets[@]}"; do
  IFS=':' read -r u pw d want_pgmq <<<"$t"
  u=$(urldecode "$u"); pw=$(urldecode "$pw"); d=$(urldecode "$d")

  psql_admin -d postgres -v u="$u" -v pw="$pw" -v d="$d" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'u')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'u') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'u', :'pw') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'d', :'u')
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'d') \gexec
SQL

  if [ "${want_pgmq:-0}" = 1 ]; then
    # in pgmq mode the fetcher keeps its cache in the cache table (hstore) in this same DB
    psql_admin -d "$d" -c 'CREATE EXTENSION IF NOT EXISTS hstore' >/dev/null
    has=$(psql_admin -d "$d" -c "SELECT to_regnamespace('pgmq') IS NOT NULL")
    # run as the DB owner so the application owns the pgmq schema (pgmq.create)
    [ "$has" = t ] || PGPASSWORD="$pw" psql -qX -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$u" -d "$d" -f "$PGMQ_SQL" >/dev/null
  fi
done
