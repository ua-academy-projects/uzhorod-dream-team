#!/usr/bin/env bash

APP=/opt/kyiv-air
CONFIG=/etc/kyiv-air
NETWORK=kyiv-air
READY_TIMEOUT=${READY_TIMEOUT:-300}
export DEBIAN_FRONTEND=noninteractive

fail() { echo "$*" >&2; exit 1; }
env_value() { sed -n "s/^$2=//p" "$1" | tr -d '\r'; }
require_env() { [[ -s "/tmp/kyiv-air-$1.env" ]] || fail "Missing env/$1.env. Run full provisioning."; }

cleanup_uploads() {
  rm -f /tmp/kyiv-air-{fetcher,history,db,ui,rabbitmq}.env /tmp/kyiv-air-{common,docker,docker-firewall}.sh /tmp/kyiv-air-images.env
}

copy_env() {
  require_env "$1"
  install -m 0600 "/tmp/kyiv-air-$1.env" "$CONFIG/$1.env"
  sed -i 's/\r$//' "$CONFIG/$1.env"
}

set_env() {
  sed -i "/^$2=/d" "$CONFIG/$1.env"
  printf '\n%s=%s\n' "$2" "$3" >> "$CONFIG/$1.env"
}

validate_password() {
  [[ "$2" =~ ^[A-Za-z0-9_-]+$ && ${#2} -ge "$3" && "$2" != *change_me* && "$2" != *your_* ]] ||
    fail "$1 must contain at least $3 unquoted letters, digits, underscores or hyphens, without placeholders."
}

read_database() {
  require_env db
  DB_NAME=$(env_value /tmp/kyiv-air-db.env POSTGRES_DB)
  DB_PASSWORD=$(env_value /tmp/kyiv-air-db.env POSTGRES_PASSWORD)
  REDIS_PASSWORD=$(env_value /tmp/kyiv-air-db.env REDIS_PASSWORD)
  [[ "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]] || fail "POSTGRES_DB must be a lowercase identifier."
  validate_password POSTGRES_PASSWORD "$DB_PASSWORD" 16
  validate_password REDIS_PASSWORD "$REDIS_PASSWORD" 32
  DATABASE_URL="postgres://kyiv_air:${DB_PASSWORD}@${DB_HOST}:5432/${DB_NAME}?sslmode=disable"
  REDIS_URL="redis://:${REDIS_PASSWORD}@${REDIS_HOST}:6379/0"
}

read_rabbitmq() {
  require_env rabbitmq
  RABBITMQ_PASSWORD=$(env_value /tmp/kyiv-air-rabbitmq.env RABBITMQ_PASSWORD)
  validate_password RABBITMQ_PASSWORD "$RABBITMQ_PASSWORD" 32
  RABBITMQ_URL="amqp://kyiv_air:${RABBITMQ_PASSWORD}@${RABBITMQ_HOST}:5672/kyiv-air"
}

validate_fetcher() {
  require_env fetcher
  local key
  key=$(env_value /tmp/kyiv-air-fetcher.env OPENAQ_API_KEY)
  [[ "$key" =~ ^[A-Za-z0-9_-]+$ && "$key" != your_openaq_api_key_here ]] || fail "Set an actual OPENAQ_API_KEY in env/fetcher.env."
}

install_docker() {
  [[ $(uname -m) == x86_64 ]] || fail "This deployment requires an amd64 guest."
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg openssl
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod 0644 /etc/apt/keyrings/docker.asc
  echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable' > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  local major
  major=$(docker version --format '{{.Client.Version}}' | cut -d. -f1)
  (( major >= 28 )) || fail "Docker 28 or newer is required for loopback port isolation."
  systemctl enable --now docker
  install -d -m 0755 "$APP/bin"
  install -d -m 0700 "$CONFIG"
  install -m 0644 "$HELPERS/images.env" "$APP/images.env"
  source "$APP/images.env"
}

configure_firewall() {
  local key
  {
    for key in ROLE PRIVATE_IP LAN_SUBNET HISTORY_IP FETCHER_IP SERVICE_PORT; do
      printf '%s=%q\n' "$key" "${!key:-}"
    done
  } > "$CONFIG/firewall.env"
  chmod 0644 "$CONFIG/firewall.env"
  install -m 0755 "$HELPERS/docker-firewall.sh" "$APP/bin/docker-firewall.sh"
  if command -v ufw >/dev/null; then ufw --force disable; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends netfilter-persistent
  cat > /usr/share/netfilter-persistent/plugins.d/25-kyiv-air <<'PLUGIN'
#!/usr/bin/env bash
set -e
case "$1" in
  start|restart|reload) /opt/kyiv-air/bin/docker-firewall.sh ;;
  save|stop|flush) ;;
esac
PLUGIN
  chmod 0755 /usr/share/netfilter-persistent/plugins.d/25-kyiv-air
  systemctl enable netfilter-persistent
  "$APP/bin/docker-firewall.sh"
}

ensure_network() {
  if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
    docker network create --driver bridge --opt com.docker.network.bridge.name=kyiv-air0 "$NETWORK"
  fi
}

build_image() {
  docker build --tag "$2" "${@:3}" "$SOURCE/$1"
}

replace_container() {
  local name=$1
  shift
  if docker container inspect "$name" >/dev/null 2>&1; then
    docker stop --timeout 30 "$name" >/dev/null
    docker rm "$name" >/dev/null
  fi
  docker run --detach --name "$name" --network "$NETWORK" --restart unless-stopped \
    --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 "$@"
}

wait_command() {
  local description=$1 deadline=$((SECONDS + READY_TIMEOUT)) remaining
  shift
  while (( SECONDS < deadline )); do
    remaining=$((deadline - SECONDS))
    (( remaining > 5 )) && remaining=5
    if timeout "${remaining}s" "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  docker ps --format 'table {{.Names}}\t{{.Status}}'
  fail "Timed out waiting for $description. Inspect docker logs kyiv-air-<component>."
}

wait_http() { wait_command "$1" curl -fsS --connect-timeout 2 --max-time 3 "$1"; }
wait_tcp() { wait_command "$1:$2" bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$1" "$2"; }

prepare_db_environment() {
  copy_env db
  set_env db POSTGRES_USER kyiv_air
  set_env db POSTGRES_PASSWORD "$DB_PASSWORD"
  sed -i '/^REDIS_PASSWORD=/d' "$CONFIG/db.env"
  printf 'REDISCLI_AUTH=%s\n' "$REDIS_PASSWORD" > "$CONFIG/redis-probe.env"
  chmod 0600 "$CONFIG/redis-probe.env"
  cat > "$CONFIG/redis.conf" <<REDIS
bind 0.0.0.0
protected-mode yes
requirepass $REDIS_PASSWORD
dir /data
appendonly yes
appendfsync everysec
save ""
maxmemory 128mb
maxmemory-policy allkeys-lru
REDIS
  chmod 0644 "$CONFIG/redis.conf"
  cat > "$CONFIG/rabbitmq.env" <<RABBIT
RABBITMQ_DEFAULT_USER=kyiv_air
RABBITMQ_DEFAULT_PASS=$RABBITMQ_PASSWORD
RABBITMQ_DEFAULT_VHOST=kyiv-air
RABBITMQ_NODENAME=rabbit@kyiv-air-rabbitmq
RABBIT
  chmod 0600 "$CONFIG/rabbitmq.env"
  printf 'vm_memory_high_watermark.absolute = 512MB\n' > "$CONFIG/rabbitmq.conf"
  chmod 0644 "$CONFIG/rabbitmq.conf"
}

start_databases() {
  local address=${PRIVATE_IP:-127.0.0.1}
  local -a pg_ports redis_ports rabbit_ports
  if [[ "$ROLE" == single ]]; then
    pg_ports=(-p 5432:5432)
    redis_ports=(-p 127.0.0.1:6379:6379)
    rabbit_ports=(-p 127.0.0.1:5672:5672)
  else
    pg_ports=(-p "$address:5432:5432" -p 127.0.0.1:5432:5432)
    redis_ports=(-p "$address:6379:6379" -p 127.0.0.1:6379:6379)
    rabbit_ports=(-p "$address:5672:5672" -p 127.0.0.1:5672:5672)
  fi
  docker pull "$POSTGRES_IMAGE"
  docker pull "$REDIS_IMAGE"
  docker pull "$RABBITMQ_IMAGE"
  for component in postgres redis rabbitmq; do docker volume create "kyiv-air-$component-data" >/dev/null; done
  replace_container kyiv-air-postgres "${pg_ports[@]}" --env-file "$CONFIG/db.env" \
    -v kyiv-air-postgres-data:/var/lib/postgresql/data "$POSTGRES_IMAGE"
  wait_command PostgreSQL docker exec kyiv-air-postgres pg_isready -h 127.0.0.1 -U kyiv_air -d "$DB_NAME"
  wait_command "PostgreSQL database" docker exec kyiv-air-postgres psql -U kyiv_air -d "$DB_NAME" -v ON_ERROR_STOP=1 -c 'SELECT 1'
  docker exec -i kyiv-air-postgres psql -U kyiv_air -d "$DB_NAME" -v ON_ERROR_STOP=1 < <(
    printf "\\set password '%s'\n" "$DB_PASSWORD"
    printf "ALTER ROLE kyiv_air WITH PASSWORD :'password';\n"
  ) >/dev/null
  replace_container kyiv-air-redis "${redis_ports[@]}" \
    -v kyiv-air-redis-data:/data -v "$CONFIG/redis.conf:/usr/local/etc/redis/redis.conf:ro" \
    "$REDIS_IMAGE" redis-server /usr/local/etc/redis/redis.conf
  wait_command Redis docker run --rm --network "$NETWORK" --env-file "$CONFIG/redis-probe.env" \
    "$REDIS_IMAGE" sh -c '[ "$(redis-cli -h kyiv-air-redis PING)" = PONG ]'
  replace_container kyiv-air-rabbitmq "${rabbit_ports[@]}" -p 127.0.0.1:15672:15672 \
    --hostname kyiv-air-rabbitmq --env-file "$CONFIG/rabbitmq.env" \
    -v kyiv-air-rabbitmq-data:/var/lib/rabbitmq -v "$CONFIG/rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro" "$RABBITMQ_IMAGE"
  wait_command RabbitMQ docker exec kyiv-air-rabbitmq rabbitmq-diagnostics -q check_running
  docker exec kyiv-air-rabbitmq sh -c 'rabbitmqctl -q change_password kyiv_air "$RABBITMQ_DEFAULT_PASS" >/dev/null 2>&1' || fail "Could not update RabbitMQ credentials."
  docker exec kyiv-air-rabbitmq rabbitmqctl -q set_permissions -p kyiv-air kyiv_air '.*' '.*' '.*'
  docker exec kyiv-air-rabbitmq rabbitmqctl -q set_user_tags kyiv_air management
  docker exec kyiv-air-rabbitmq sh -c 'rabbitmqctl -q authenticate_user kyiv_air "$RABBITMQ_DEFAULT_PASS" >/dev/null 2>&1' || fail "RabbitMQ authentication failed."
  wait_command AMQP docker exec kyiv-air-rabbitmq rabbitmq-diagnostics -q check_port_listener 5672
}

prepare_fetcher_environment() {
  copy_env fetcher
  set_env fetcher PORT 8080
  set_env fetcher RABBITMQ_URL "$RABBITMQ_URL"
}

prepare_history_environment() {
  copy_env history
  set_env history PORT 8081
  set_env history DATABASE_URL "$DATABASE_URL"
  set_env history REDIS_URL "$REDIS_URL"
  set_env history RABBITMQ_URL "$RABBITMQ_URL"
  set_env history ALLOWED_ORIGINS "$UI_ORIGIN"
  printf 'GOOSE_DBSTRING=%s\n' "$DATABASE_URL" > "$CONFIG/migrate.env"
  chmod 0600 "$CONFIG/migrate.env"
}

wait_dependencies() {
  local probe
  wait_tcp "$RABBITMQ_HOST" 5672
  if [[ "$ROLE" == history ]]; then
    probe=(docker run --rm --network "$NETWORK" --env-file "$CONFIG/history.env" --env-file "$CONFIG/redis-probe.env")
    wait_command PostgreSQL "${probe[@]}" -e PGCONNECT_TIMEOUT=3 --entrypoint sh "$POSTGRES_IMAGE" -c \
      'psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "SELECT 1"'
    wait_command Redis "${probe[@]}" -e "REDIS_HOST=$REDIS_HOST" "$REDIS_IMAGE" sh -c \
      '[ "$(redis-cli -h "$REDIS_HOST" PING)" = PONG ]'
  fi
}

migrate_database() {
  docker run --rm --name kyiv-air-migrate --network "$NETWORK" --env-file "$CONFIG/migrate.env" "$MIGRATION_IMAGE" up
}

start_backend() {
  local role=$1 image=$2 port=$3
  local -a ports
  if [[ "$ROLE" == single ]]; then ports=(-p "$port:$port"); else ports=(-p "$PRIVATE_IP:$port:$port" -p "127.0.0.1:$port:$port"); fi
  replace_container "kyiv-air-$role" "${ports[@]}" --env-file "$CONFIG/$role.env" \
    --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m --cap-drop ALL --security-opt no-new-privileges "$image"
  wait_http "http://127.0.0.1:$port/health"
}

start_ui() {
  local -a ports
  copy_env ui
  set_env ui HISTORY_URL "$HISTORY_URL"
  if [[ "$ROLE" == single ]]; then ports=(-p 5173:80); else ports=(-p "$PRIVATE_IP:5173:80" -p 127.0.0.1:5173:80); fi
  replace_container kyiv-air-ui "${ports[@]}" --env-file "$CONFIG/ui.env" "$UI_IMAGE"
  wait_http http://127.0.0.1:5173/
  wait_http http://127.0.0.1:5173/api/v1/session
}
