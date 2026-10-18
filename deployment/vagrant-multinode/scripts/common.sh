#!/usr/bin/env bash
set -Eeuo pipefail

APP=/opt/kyiv-air
CONFIG=/etc/kyiv-air
NETWORK=kyiv-air
READY_TIMEOUT=${READY_TIMEOUT:-300}
POSTGRES_ONLY=${POSTGRES_ONLY:-false}
[[ "$POSTGRES_ONLY" == true || "$POSTGRES_ONLY" == false ]] || { echo "Invalid POSTGRES_ONLY" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

fail() { echo "$*" >&2; exit 1; }
env_value() { sed -n "s/^$2=//p" "$1" | tr -d '\r'; }
require_env() { [[ -s "/tmp/kyiv-air-$1.env" ]] || fail "Missing env/$1.env. Run full provisioning."; }

cleanup_uploads() {
  rm -f /tmp/kyiv-air-{fetcher,history,db,ui,rabbitmq,queue,cloudflare}.env /tmp/kyiv-air-{common,docker-firewall}.sh /tmp/kyiv-air-images.env /tmp/kyiv-air-bastion.conf.template
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
  if [[ "$POSTGRES_ONLY" == false ]]; then validate_password REDIS_PASSWORD "$REDIS_PASSWORD" 32; fi
  DATABASE_URL="postgres://kyiv_air:${DB_PASSWORD}@${DB_HOST}:5432/${DB_NAME}?sslmode=disable"
  REDIS_URL="redis://:${REDIS_PASSWORD}@${REDIS_HOST}:6379/0"
}

read_queue() {
  require_env queue
  QUEUE_DB_NAME=$(env_value /tmp/kyiv-air-queue.env POSTGRES_DB)
  FETCHER_DB_PASSWORD=$(env_value /tmp/kyiv-air-queue.env POSTGRES_FETCHER_PASSWORD)
  [[ "$QUEUE_DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]] || fail "POSTGRES_DB in queue.env must be a lowercase identifier."
  validate_password POSTGRES_FETCHER_PASSWORD "$FETCHER_DB_PASSWORD" 16
  FETCHER_DATABASE_URL="postgres://kyiv_air_fetcher:${FETCHER_DB_PASSWORD}@${DB_HOST}:5432/${QUEUE_DB_NAME}?sslmode=disable"
}

read_rabbitmq() {
  require_env rabbitmq
  RABBITMQ_PASSWORD=$(env_value /tmp/kyiv-air-rabbitmq.env RABBITMQ_PASSWORD)
  validate_password RABBITMQ_PASSWORD "$RABBITMQ_PASSWORD" 32
  RABBITMQ_URL="amqp://kyiv_air:${RABBITMQ_PASSWORD}@${RABBITMQ_HOST}:5672/kyiv-air"
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
    for key in POSTGRES_ONLY ROLE PRIVATE_IP PRIVATE_SUBNET PUBLIC_IP BASTION_IP HISTORY_IP FETCHER_IP SERVICE_PORT; do
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

require_ca_bundle() {
  [[ -s /etc/ssl/certs/ca-certificates.crt && -r /etc/ssl/certs/ca-certificates.crt ]] ||
    fail "Missing or unreadable VM CA bundle: /etc/ssl/certs/ca-certificates.crt"
}

start_backend() {
  local role=$1 image=$2 port=$3
  local -a ports=(-p "$PRIVATE_IP:$port:$port" -p "127.0.0.1:$port:$port")
  require_ca_bundle
  replace_container "kyiv-air-$role" "${ports[@]}" --env-file "$CONFIG/$role.env" \
    --mount type=bind,src=/etc/ssl/certs/ca-certificates.crt,dst=/etc/ssl/certs/ca-certificates.crt,readonly \
    -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m --cap-drop ALL --security-opt no-new-privileges "$image"
  wait_http "http://127.0.0.1:$port/health"
}

trap cleanup_uploads EXIT
SOURCE=$APP/source
HELPERS=$APP/helpers
DB_HOST=$DB_IP
REDIS_HOST=$DB_IP
RABBITMQ_HOST=$DB_IP
install -d -m 0755 "$HELPERS"
install -m 0644 /tmp/kyiv-air-images.env "$HELPERS/images.env"
install -m 0755 /tmp/kyiv-air-docker-firewall.sh "$HELPERS/docker-firewall.sh"
