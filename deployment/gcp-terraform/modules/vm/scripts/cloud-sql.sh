#!/usr/bin/env bash
start_sql_proxy() {
  : "${CLOUD_SQL_CONNECTION:?Missing Cloud SQL connection name}"
  local image=${CLOUD_SQL_PROXY_IMAGE:-gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.18.2}
  docker pull "$image"
  replace_container kyiv-air-sql-proxy "$image" --address=0.0.0.0 --port=5432 --psc "$CLOUD_SQL_CONNECTION"
  DB_HOST=kyiv-air-sql-proxy
}

migrate_database() {
  local password
  password=$(get_secret postgres-migration-password)
  validate_password POSTGRES_MIGRATION_PASSWORD "$password" 32
  export GOOSE_DBSTRING="postgres://kyiv_air_migrate:${password}@kyiv-air-sql-proxy:5432/${POSTGRES_DB}?sslmode=disable"
  export HISTORY_DB_PASSWORD
  HISTORY_DB_PASSWORD=$(get_secret postgres-history-password)
  local env_args=(-e GOOSE_DBSTRING -e HISTORY_DB_PASSWORD -e POSTGRES_ONLY -e CLOUD_SQL)
  export POSTGRES_ONLY CLOUD_SQL=true
  if [[ "$POSTGRES_ONLY" == true ]]; then
    export FETCHER_DB_PASSWORD
    FETCHER_DB_PASSWORD=$(get_secret postgres-fetcher-password)
    env_args+=(-e FETCHER_DB_PASSWORD)
  fi
  docker pull "$POSTGRES_CLIENT_IMAGE"
  wait_command 'Cloud SQL' docker run --rm --network "$NETWORK" "${env_args[@]}" \
    -e PGCONNECT_TIMEOUT=3 "$POSTGRES_CLIENT_IMAGE" sh -c 'psql "$GOOSE_DBSTRING" -v ON_ERROR_STOP=1 -c "SELECT 1"'
  pull_image "$MIGRATION_IMAGE"
  docker run --rm --name kyiv-air-migrate --network "$NETWORK" "${env_args[@]}" "$MIGRATION_IMAGE" up
  unset GOOSE_DBSTRING HISTORY_DB_PASSWORD FETCHER_DB_PASSWORD password
}
