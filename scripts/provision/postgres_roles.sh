#!/bin/bash
set -euo pipefail

cd /opt/iss

for _ in $(seq 1 30); do
  if docker compose exec -T postgres sh -c 'pg_isready -q -U "$POSTGRES_USER" -d "$POSTGRES_DB"'; then
    break
  fi
  sleep 2
done

docker compose exec -T postgres sh -c \
  'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v role="$POSTGRES_FETCHER_USER" -v pass="$POSTGRES_FETCHER_PASSWORD"' <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'role')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'role', :'pass') \gexec
SQL

echo "fetcher database role is ready"
