#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE=/opt/kyiv-air/source
APP=/opt/kyiv-air
CONFIG=/etc/kyiv-air
source "$SOURCE/deployment/scripts/redis.sh"
source "$SOURCE/deployment/scripts/rabbitmq.sh"
READY_TIMEOUT=${READY_TIMEOUT:-300}
NODE_MAJOR=24
PNPM_VERSION=10.33.0
GOOSE_VERSION=3.24.3
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/bin:/sbin"
export GOTOOLCHAIN=auto

# Remove temporary uploads on exit, including error exits, because they contain credentials.
cleanup() {
  rm -f /tmp/kyiv-air-{fetcher,history,db,ui}.env "${PG_CONFIG_TEMP:-}" "${PG_HBA_TEMP:-}" \
    "${REDIS_CONFIG_TEMP:-}" "${REDIS_MAIN_TEMP:-}" "${RABBITMQ_CONFIG_TEMP:-}" "${RABBITMQ_ENV_TEMP:-}" "${RABBITMQ_SOCKET_TEMP:-}"
}

validate_environment() {
  for service in fetcher history db ui; do
    if [[ ! -s "/tmp/kyiv-air-$service.env" ]]; then
      echo "Missing $service env file. Run vagrant provision to upload deployment/vagrant-singlenode/env/$service.env." >&2
      exit 1
    fi
  done

  OPENAQ_API_KEY=$(sed -n 's/^OPENAQ_API_KEY=//p' /tmp/kyiv-air-fetcher.env | tr -d '\r')
  if [[ ! "$OPENAQ_API_KEY" =~ ^[A-Za-z0-9_-]+$ || "$OPENAQ_API_KEY" == "your_openaq_api_key_here" ]]; then
    echo "Set an actual unquoted OPENAQ_API_KEY in deployment/vagrant-singlenode/env/fetcher.env." >&2
    exit 1
  fi

  DB_NAME=$(sed -n 's/^POSTGRES_DB=//p' /tmp/kyiv-air-db.env | tr -d '\r')
  if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo "POSTGRES_DB in env/db.env must be an unquoted database name using lowercase letters, digits, and underscores." >&2
    exit 1
  fi
}

install_packages() {
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git build-essential golang-go rsync \
    postgresql-16 postgresql-client-16 redis-server redis-tools ufw

  if [[ $(uname -m) != "x86_64" ]]; then
    echo "This deployment uses an amd64 box and requires an x86_64 guest." >&2
    exit 1
  fi
}

install_node() {
  # Create a readable keyring directory. Download NodeSource's signing key over HTTPS,
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL --retry 3 https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --batch --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg
  chmod 0644 /etc/apt/keyrings/nodesource.gpg

  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  # Priority 600 makes NodeSource's nodejs package preferred over the normal priority 500.
  cat > /etc/apt/preferences.d/nodejs <<'APT'
Package: nodejs
Pin: origin deb.nodesource.com
Pin-Priority: 600
APT

  apt-get update
  apt-get install -y --no-install-recommends nodejs

  hash -r
  if [[ $(node --version) != v${NODE_MAJOR}.* ]]; then
    echo "Expected Node ${NODE_MAJOR}.x from NodeSource after installing nodejs." >&2
    exit 1
  fi
}

install_pnpm() {
  if ! command -v pnpm >/dev/null || [[ $(pnpm --version) != "$PNPM_VERSION" ]]; then
    npm install --global "pnpm@$PNPM_VERSION"
  fi
}

install_goose() {
  if [[ ! -x /usr/local/bin/goose ]] || ! goose --version | grep -q "${GOOSE_VERSION}"; then
    GOBIN=/usr/local/bin go install -tags='no_clickhouse no_libsql no_mssql no_mysql no_sqlite3 no_vertica no_ydb' \
      "github.com/pressly/goose/v3/cmd/goose@v${GOOSE_VERSION}"
  fi
}

build_applications() {
  install -d -m 0755 "$APP/bin"

  for service in fetcher history; do
    runuser -u vagrant -- env PATH="$PATH" GOTOOLCHAIN="$GOTOOLCHAIN" bash -c \
      'set -e; cd "$1"; go build -trimpath -o /tmp/kyiv-air-"$2" ./cmd/"$2"' \
      bash "$SOURCE/$service" "$service"
  done

  runuser -u vagrant -- env PATH="$PATH" bash -c \
    'set -e; cd "$1"; pnpm install --frozen-lockfile' bash "$SOURCE/ui"
}

prepare_runtime() {
  id kyiv-air >/dev/null 2>&1 || useradd --system --user-group --home-dir "$APP" --shell /usr/sbin/nologin kyiv-air

  install -d -m 0700 "$CONFIG"
}

prepare_database_credentials() {
  if [[ ! -s "$CONFIG/db-password" ]]; then
    node -e 'console.log(require("node:crypto").randomBytes(32).toString("hex"))' > "$CONFIG/db-password"
  fi

  chmod 0600 "$CONFIG/db-password"
  DB_PASSWORD=$(cat "$CONFIG/db-password")

  DATABASE_URL="postgres://kyiv_air:${DB_PASSWORD}@127.0.0.1:5432/${DB_NAME}?sslmode=disable"
}

prepare_redis_credentials() {
  if [[ ! -s "$CONFIG/redis-password" ]]; then
    (umask 077; node -e 'console.log(require("node:crypto").randomBytes(32).toString("hex"))' > "$CONFIG/redis-password")
  fi
  chmod 0600 "$CONFIG/redis-password"
  REDIS_PASSWORD=$(cat "$CONFIG/redis-password")
  validate_redis_password "$REDIS_PASSWORD"
  REDIS_URL="redis://:${REDIS_PASSWORD}@127.0.0.1:6379/0"
}

prepare_rabbitmq_credentials() {
  if [[ ! -s "$CONFIG/rabbitmq-password" ]]; then
    (umask 077; node -e 'console.log(require("node:crypto").randomBytes(32).toString("hex"))' > "$CONFIG/rabbitmq-password")
  fi
  chmod 0600 "$CONFIG/rabbitmq-password"
  RABBITMQ_PASSWORD=$(cat "$CONFIG/rabbitmq-password")
  validate_rabbitmq_password "$RABBITMQ_PASSWORD"
  RABBITMQ_URL="amqp://kyiv_air:${RABBITMQ_PASSWORD}@127.0.0.1:5672/kyiv-air"
}

install_environment_files() {
  for service in fetcher history db ui; do
    install -m 0600 "/tmp/kyiv-air-$service.env" "$CONFIG/$service.env"
  done

  printf '\nDATABASE_URL=%s\n' "$DATABASE_URL" >> "$CONFIG/history.env"
  sed -i '/^REDIS_URL=/d' "$CONFIG/history.env"
  printf '\nREDIS_URL=%s\n' "$REDIS_URL" >> "$CONFIG/history.env"
  sed -i '/^FETCHER_SERVICE_URL=/d' "$CONFIG/history.env"
  for service in fetcher history; do
    sed -i '/^RABBITMQ_URL=/d' "$CONFIG/$service.env"
    printf '\nRABBITMQ_URL=%s\n' "$RABBITMQ_URL" >> "$CONFIG/$service.env"
  done
}

stop_applications() {
  systemctl stop kyiv-air-ui.service kyiv-air-history.service kyiv-air-fetcher.service 2>/dev/null || true
}

configure_postgresql() {
  PG_CLUSTER=/etc/postgresql/16/main
  PG_CONFIG_TEMP=$(mktemp)
  PG_HBA_TEMP=$(mktemp)

  install -d -m 0755 "$PG_CLUSTER/conf.d"
  cat > "$PG_CONFIG_TEMP" <<'PGCONF'
# Managed by Kyiv air provisioning: accept forwarded connections from either provider.
listen_addresses = '*'
password_encryption = 'scram-sha-256'
PGCONF

  {
    printf '# BEGIN KYIV-AIR MANAGED ACCESS\n'
    printf 'host "%s" kyiv_air samenet scram-sha-256\n' "$DB_NAME"
    printf '# END KYIV-AIR MANAGED ACCESS\n'
    awk '
      /^# BEGIN KYIV-AIR MANAGED ACCESS$/ { managed = 1; next }
      /^# END KYIV-AIR MANAGED ACCESS$/ { managed = 0; next }
      !managed { print }
    ' "$PG_CLUSTER/pg_hba.conf"
  } > "$PG_HBA_TEMP"

  PG_CONFIG_CHANGED=false
  if ! cmp -s "$PG_CONFIG_TEMP" "$PG_CLUSTER/conf.d/kyiv-air.conf"; then
    install -o postgres -g postgres -m 0644 "$PG_CONFIG_TEMP" "$PG_CLUSTER/conf.d/kyiv-air.conf"
    PG_CONFIG_CHANGED=true
  fi
  if ! cmp -s "$PG_HBA_TEMP" "$PG_CLUSTER/pg_hba.conf"; then
    install -o postgres -g postgres -m 0640 "$PG_HBA_TEMP" "$PG_CLUSTER/pg_hba.conf"
    PG_CONFIG_CHANGED=true
  fi

  systemctl enable --now postgresql postgresql@16-main

  if [[ "$PG_CONFIG_CHANGED" == true ]]; then
    systemctl restart postgresql@16-main
  fi

  pg_isready -q

  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -v password="$DB_PASSWORD" -v database="$DB_NAME" <<'SQL'
SELECT 'CREATE ROLE kyiv_air LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kyiv_air') \gexec
SET password_encryption = 'scram-sha-256';
ALTER ROLE kyiv_air WITH PASSWORD :'password';
SELECT format('CREATE DATABASE %I OWNER kyiv_air', :'database') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'database') \gexec
SQL

}

migrate_database() {
  GOOSE_DRIVER=postgres GOOSE_DBSTRING="$DATABASE_URL" \
    goose -dir "$SOURCE/history/internal/db/migrations" up
}

install_binaries() {
  for service in fetcher history; do
    install -m 0755 "/tmp/kyiv-air-$service" "$APP/bin/$service"
    rm -f "/tmp/kyiv-air-$service"
  done
}

install_service_units() {
  local service description runtime_user working_directory command
  local dependencies required_services start_check environment protections

  for service in fetcher history ui; do
    description="Kyiv air quality $service service"
    runtime_user=kyiv-air
    working_directory=$APP
    command="$APP/bin/$service"
    dependencies="network-online.target"
    required_services=""
    start_check=""
    environment=""
    protections=$'ProtectSystem=strict\nProtectHome=true'

    if [[ "$service" == "fetcher" || "$service" == "history" ]]; then
      dependencies="$dependencies rabbitmq-server.service"
      required_services="rabbitmq-server.service"
      start_check="ExecStartPre=$APP/bin/wait-ready.sh tcp 127.0.0.1 5672 $READY_TIMEOUT"
    fi

    if [[ "$service" == "history" ]]; then
      dependencies="$dependencies postgresql@16-main.service redis-server.service"
      required_services="$required_services postgresql@16-main.service redis-server.service"
    elif [[ "$service" == "ui" ]]; then
      description="Kyiv air quality Vite development server"
      runtime_user=vagrant
      working_directory="$SOURCE/ui"
      command="/usr/bin/env pnpm run dev --host 0.0.0.0"
      dependencies="$dependencies kyiv-air-history.service"
      required_services="kyiv-air-history.service"
      environment="Environment=\"PATH=$PATH\""
      protections=""
    fi

    cat > "/etc/systemd/system/kyiv-air-$service.service" <<UNIT
[Unit]
Description=$description
Wants=network-online.target $required_services
After=$dependencies
StartLimitIntervalSec=0

[Service]
Type=simple
User=$runtime_user
Group=$runtime_user
WorkingDirectory=$working_directory
$environment
EnvironmentFile=$CONFIG/$service.env
$start_check
ExecStart=$command
TimeoutStartSec=$((READY_TIMEOUT + 30))
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
$protections
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

  done
}

start_applications() {
  systemctl daemon-reload
  systemctl enable --now kyiv-air-fetcher
  systemctl enable --now kyiv-air-history
  systemctl enable --now kyiv-air-ui
}

configure_firewall() {
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  for port in 5173 8080 8081 5432; do
    ufw allow "$port/tcp"
  done
}

verify_startup() {
  curl -fsS --retry 20 --retry-connrefused --retry-delay 1 http://127.0.0.1:8081/api/v1/locations >/dev/null
  curl -fsS --retry 20 --retry-connrefused --retry-delay 1 --connect-timeout 2 --max-time 3 http://127.0.0.1:8081/api/v1/session >/dev/null
  curl -fsS --retry 20 --retry-connrefused --retry-delay 1 http://127.0.0.1:5173/ >/dev/null

  echo "Application ready at http://localhost:5173 on the host. History is collecting OpenAQ data in the background."
}

main() {
  trap cleanup EXIT
  validate_environment
  install_packages
  install_rabbitmq
  install_node
  install_pnpm
  install_goose
  build_applications
  prepare_runtime
  prepare_database_credentials
  prepare_redis_credentials
  prepare_rabbitmq_credentials
  install_environment_files
  stop_applications
  configure_postgresql
  configure_redis 127.0.0.1 6379 "$REDIS_PASSWORD"
  configure_rabbitmq 127.0.0.1 5672 "$RABBITMQ_PASSWORD" "$READY_TIMEOUT"
  migrate_database
  install_binaries
  install -m 0755 "$SOURCE/deployment/vagrant-multinode/scripts/wait-ready.sh" "$APP/bin/wait-ready.sh"
  install_service_units
  start_applications
  configure_firewall
  verify_startup
}

main
