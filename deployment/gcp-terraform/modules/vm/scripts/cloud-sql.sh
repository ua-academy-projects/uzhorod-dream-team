#!/usr/bin/env bash
start_sql_proxy() {
  : "${CLOUD_SQL_CONNECTION:?Missing Cloud SQL connection name}"
  local image=${CLOUD_SQL_PROXY_IMAGE:-gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.18.2}
  docker pull "$image"
  replace_container kyiv-air-sql-proxy "$image" --address=0.0.0.0 --port=5432 --psc "$CLOUD_SQL_CONNECTION"
  DB_HOST=kyiv-air-sql-proxy
}
