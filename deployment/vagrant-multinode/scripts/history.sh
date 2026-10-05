#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed 's/\r$//' /tmp/kyiv-air-common.sh)

require_env history
read_database
install_go
apt-get install -y --no-install-recommends postgresql-client-16
if [[ ! -x /usr/local/bin/goose ]] || ! goose --version | grep -q "$GOOSE_VERSION"; then
  GOBIN=/usr/local/bin go install -tags='no_clickhouse no_libsql no_mssql no_mysql no_sqlite3 no_vertica no_ydb' \
    "github.com/pressly/goose/v3/cmd/goose@v${GOOSE_VERSION}"
fi
build_backend
copy_env history
set_env history PORT "$SERVICE_PORT"
set_env history DATABASE_URL "$DATABASE_URL"
set_env history FETCHER_SERVICE_URL "$FETCHER_URL"
set_env history ALLOWED_ORIGINS "$UI_ORIGIN"

copy_env db
wait_database
wait_http "$FETCHER_URL/health"

GOOSE_DRIVER=postgres GOOSE_DBSTRING="$DATABASE_URL" goose -dir "$SOURCE/history/internal/db/migrations" up

pre_start="ExecStartPre=$APP/bin/wait-ready.sh postgres $DB_IP $DB_PORT $READY_TIMEOUT
ExecStartPre=$APP/bin/wait-ready.sh http $FETCHER_URL/health 0 $READY_TIMEOUT"

install_unit kyiv-air "$APP" "$APP/bin/history" "$pre_start"
configure_firewall
start_application
wait_http "http://127.0.0.1:$SERVICE_PORT/api/v1/locations"
