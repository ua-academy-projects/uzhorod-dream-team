#!/usr/bin/env bash
set -Eeuo pipefail

APP=/opt/kyiv-air
SOURCE=$APP/source
CONFIG=/etc/kyiv-air
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/bin:/sbin"
export GOTOOLCHAIN=auto

# Remove uploaded credentials and temporary helpers even if provisioning fails.
trap 'rm -f /tmp/kyiv-air-{fetcher,history,db,ui,rabbitmq}.env /tmp/kyiv-air-{common,wait-ready,redis,rabbitmq}.sh "${PG_TEMP:-}" "${HBA_TEMP:-}" "${REDIS_CONFIG_TEMP:-}" "${REDIS_MAIN_TEMP:-}" "${RABBITMQ_CONFIG_TEMP:-}" "${RABBITMQ_ENV_TEMP:-}" "${RABBITMQ_SOCKET_TEMP:-}"' EXIT

fail() { echo "$*" >&2; exit 1; }

require_env() {
  [[ -s "/tmp/kyiv-air-$1.env" ]] || fail "Missing env/$1.env. Run full vagrant provision for $ROLE."
}

# Usage: env_value test.env ENVIRONMENT
env_value() { sed -n "s/^$2=//p" "$1" | tr -d '\r'; }

read_database() {
  require_env db
  DB_NAME=$(env_value /tmp/kyiv-air-db.env POSTGRES_DB)
  DB_PASSWORD=$(env_value /tmp/kyiv-air-db.env POSTGRES_PASSWORD)
  [[ "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]] || fail "POSTGRES_DB must be an unquoted lowercase identifier."

  [[ "$DB_PASSWORD" =~ ^[A-Za-z0-9_-]{16,}$ && "$DB_PASSWORD" != "change_me_before_starting" ]] ||
    fail "Set POSTGRES_PASSWORD in env/db.env: at least 16 unquoted letters, digits, underscores or hyphens."
  DATABASE_URL="postgres://kyiv_air:${DB_PASSWORD}@${DB_IP}:${DB_PORT}/${DB_NAME}?sslmode=disable"
}

read_redis() {
  require_env db
  REDIS_PASSWORD=$(env_value /tmp/kyiv-air-db.env REDIS_PASSWORD)
  validate_redis_password "$REDIS_PASSWORD"
  REDIS_URL="redis://:${REDIS_PASSWORD}@${DB_IP}:${REDIS_PORT}/0"
}

read_rabbitmq() {
  require_env rabbitmq
  RABBITMQ_PASSWORD=$(env_value /tmp/kyiv-air-rabbitmq.env RABBITMQ_PASSWORD)
  validate_rabbitmq_password "$RABBITMQ_PASSWORD"
  RABBITMQ_URL="amqp://kyiv_air:${RABBITMQ_PASSWORD}@${DB_IP}:${RABBITMQ_PORT}/kyiv-air"
}

base_packages() {
  [[ $(uname -m) == x86_64 ]] || fail "This deployment requires an amd64 guest."
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl ufw "$@"
  install -d -m 0755 "$APP/bin"
  install -d -m 0700 "$CONFIG"

  sed 's/\r$//' /tmp/kyiv-air-wait-ready.sh > "$APP/bin/wait-ready.sh"
  chmod 0755 "$APP/bin/wait-ready.sh"
}

copy_env() {
  require_env "$1"
  install -m 0600 "/tmp/kyiv-air-$1.env" "$CONFIG/$1.env"
  sed -i 's/\r$//' "$CONFIG/$1.env"
}

# Usage: set_env test.env ENVIRONMENT development
set_env() {
  sed -i "/^$2=/d" "$CONFIG/$1.env"
  printf '\n%s=%s\n' "$2" "$3" >> "$CONFIG/$1.env"
}

configure_firewall() {
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  ufw allow 22/tcp
  ufw allow from "$LAN_SUBNET" to "$PRIVATE_IP" port "$SERVICE_PORT" proto tcp
  if [[ "$ROLE" == "db" ]]; then
    ufw allow from "$HISTORY_IP" to "$PRIVATE_IP" port "$REDIS_PORT" proto tcp
    ufw allow from "$FETCHER_IP" to "$PRIVATE_IP" port "$RABBITMQ_PORT" proto tcp
    ufw allow from "$HISTORY_IP" to "$PRIVATE_IP" port "$RABBITMQ_PORT" proto tcp
  fi
  ufw --force enable
}

install_go() { base_packages golang-go git build-essential rsync; }

install_node() {
  base_packages gnupg git build-essential rsync
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL --retry 3 https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg
  chmod 0644 /etc/apt/keyrings/nodesource.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
  cat > /etc/apt/preferences.d/nodejs <<'APT'
Package: nodejs
Pin: origin deb.nodesource.com
Pin-Priority: 600
APT
  apt-get update
  apt-get install -y --no-install-recommends nodejs
  hash -r
  [[ $(node --version) == v${NODE_MAJOR}.* ]] || fail "Expected Node ${NODE_MAJOR}.x."
  if ! command -v pnpm >/dev/null || [[ $(pnpm --version) != "$PNPM_VERSION" ]]; then
    npm install --global "pnpm@$PNPM_VERSION"
  fi
}

build_backend() {
  id kyiv-air >/dev/null 2>&1 || useradd --system --user-group --home-dir "$APP" --shell /usr/sbin/nologin kyiv-air
  runuser -u vagrant -- env PATH="$PATH" GOTOOLCHAIN="$GOTOOLCHAIN" bash -c \
    'set -e; cd "$1"; go build -trimpath -o /tmp/kyiv-air-"$2" ./cmd/"$2"' bash "$SOURCE/$ROLE" "$ROLE"

  systemctl stop "kyiv-air-$ROLE.service" 2>/dev/null || true
  install -m 0755 "/tmp/kyiv-air-$ROLE" "$APP/bin/$ROLE"
  rm -f "/tmp/kyiv-air-$ROLE"
}

install_unit() {
  local user=$1 working_directory=$2 command=$3 pre_start=${4:-} protections=""
  if [[ "$user" == kyiv-air ]]; then
    protections=$'ProtectSystem=strict\nProtectHome=true'
  fi

  cat > "/etc/systemd/system/kyiv-air-$ROLE.service" <<UNIT
[Unit]
Description=Kyiv air quality $ROLE
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$user
Group=$user
WorkingDirectory=$working_directory
Environment="PATH=$PATH"
EnvironmentFile=$CONFIG/$ROLE.env
$pre_start
ExecStart=$command
TimeoutStartSec=$((READY_TIMEOUT * 2 + 30))
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
$protections
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
}

wait_http() { "$APP/bin/wait-ready.sh" http "$1" 0 "$READY_TIMEOUT"; }
wait_database() { "$APP/bin/wait-ready.sh" postgres "$DB_IP" "$DB_PORT" "$READY_TIMEOUT"; }
wait_broker() { "$APP/bin/wait-ready.sh" tcp "$DB_IP" "$RABBITMQ_PORT" "$READY_TIMEOUT"; }
start_application() {
  systemctl enable "kyiv-air-$ROLE.service"
  systemctl restart "kyiv-air-$ROLE.service"
}
