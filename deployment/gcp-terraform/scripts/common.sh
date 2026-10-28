#!/usr/bin/env bash
set -Eeuo pipefail

APP=${APP:-/opt/kyiv-air}
CONFIG=${CONFIG:-/etc/kyiv-air}
HELPERS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NETWORK=kyiv-air
READY_TIMEOUT=${READY_TIMEOUT:-600}
readonly SSH_PORT=${SSH_PORT:-222}
POSTGRES_ONLY=${POSTGRES_ONLY:-false}
[[ "$POSTGRES_ONLY" == true || "$POSTGRES_ONLY" == false ]] || { echo "Invalid POSTGRES_ONLY" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

fail() { echo "$*" >&2; exit 1; }
configure_ssh() {
  install -d -m 0755 /etc/ssh/sshd_config.d
  sed -i -E '/^[[:space:]]*Port[[:space:]]+/d' /etc/ssh/sshd_config
  local snippet
  for snippet in /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$snippet" ]] || continue
    sed -i -E '/^[[:space:]]*Port[[:space:]]+/d' "$snippet"
  done
  printf 'Port %s\n' "$SSH_PORT" > /etc/ssh/sshd_config.d/00-kyiv-air-port.conf
  chmod 0644 /etc/ssh/sshd_config.d/00-kyiv-air-port.conf
  /usr/sbin/sshd -t
  systemctl daemon-reload
  if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
    systemctl restart ssh.socket
  fi
  systemctl restart ssh.service
}
get_secret() {
  local name=$1 version secret
  version=$(jq -er --arg name "$name" '.[$name].version // empty' <<< "$SECRET_REFS") ||
    fail "Missing numbered version for secret $name."
  [[ "$version" =~ ^[1-9][0-9]*$ ]] || fail "Invalid version for secret $name."
  secret=$(jq -er --arg name "$name" '.[$name].secret_id' <<< "$SECRET_REFS")
  gcloud secrets versions access "$version" --project="$PROJECT_ID" --secret="$secret"
}

create_env() {
  install -d -m 0700 "$CONFIG"
  local application_env=${APPLICATION_ENV:-'{}'}
  jq -r 'to_entries[] | "\(.key)=\(.value)"' <<< "$application_env" > "$CONFIG/$1.env"
  chmod 0600 "$CONFIG/$1.env"
}

set_env() {
  [[ "$3" != *$'\n'* && "$3" != *$'\r'* ]] || fail "Invalid multiline value for $2."
  sed -i "/^$2=/d" "$CONFIG/$1.env"
  printf '%s=%s\n' "$2" "$3" >> "$CONFIG/$1.env"
}

validate_password() {
  [[ "$2" =~ ^[A-Za-z0-9_-]+$ && ${#2} -ge "$3" && "$2" != *change_me* && "$2" != *your_* ]] ||
    fail "$1 must contain at least $3 unquoted letters, digits, underscores or hyphens, without placeholders."
}

read_database() {
  DB_NAME=${POSTGRES_DB:-kyiv_air}
  DB_PASSWORD=$(get_secret postgres-history-password)
  REDIS_PASSWORD=
  if [[ "$POSTGRES_ONLY" == false ]]; then REDIS_PASSWORD=$(get_secret redis-password); fi
  [[ "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]] || fail "POSTGRES_DB must be a lowercase identifier."
  validate_password POSTGRES_PASSWORD "$DB_PASSWORD" 16
  if [[ "$POSTGRES_ONLY" == false ]]; then validate_password REDIS_PASSWORD "$REDIS_PASSWORD" 32; fi
  DATABASE_URL="postgres://kyiv_air:${DB_PASSWORD}@${DB_HOST}:5432/${DB_NAME}?sslmode=disable"
  REDIS_URL="redis://:${REDIS_PASSWORD}@${REDIS_HOST}:6379/0"
}

read_queue() {
  QUEUE_DB_NAME=${POSTGRES_DB:-kyiv_air}
  FETCHER_DB_PASSWORD=$(get_secret postgres-fetcher-password)
  [[ "$QUEUE_DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]] || fail "POSTGRES_DB must be a lowercase identifier."
  validate_password POSTGRES_FETCHER_PASSWORD "$FETCHER_DB_PASSWORD" 16
  FETCHER_DATABASE_URL="postgres://kyiv_air_fetcher:${FETCHER_DB_PASSWORD}@${DB_HOST}:5432/${QUEUE_DB_NAME}?sslmode=disable"
}

read_rabbitmq() {
  RABBITMQ_PASSWORD=$(get_secret rabbitmq-password)
  validate_password RABBITMQ_PASSWORD "$RABBITMQ_PASSWORD" 32
  RABBITMQ_URL="amqp://kyiv_air:${RABBITMQ_PASSWORD}@${RABBITMQ_HOST}:5672/kyiv-air"
}

install_docker() {
  [[ $(uname -m) == x86_64 ]] || fail "This deployment requires an amd64 guest."
  apt-get -o APT::Update::Error-Mode=any update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg openssl
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod 0644 /etc/apt/keyrings/docker.asc
  local codename
  codename=$(. /etc/os-release; printf '%s' "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
  printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' "$codename" > /etc/apt/sources.list.d/docker.list
  apt-get -o APT::Update::Error-Mode=any update
  apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io
  local major
  major=$(docker version --format '{{.Client.Version}}' | cut -d. -f1)
  (( major >= 28 )) || fail "Docker 28 or newer is required for loopback port isolation."
  systemctl enable --now docker
  install -d -m 0755 "$APP/bin"
  install -d -m 0700 "$CONFIG"
}

ensure_network() {
  if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
    docker network create --driver bridge --opt com.docker.network.bridge.name=kyiv-air0 "$NETWORK"
  fi
}

pull_image() {
  docker pull --platform linux/amd64 "$1"
}

prepare_runtime() {
  local role=$1
  umask 077
  configure_ssh
  apt-get -o APT::Update::Error-Mode=any update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg jq
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL --retry 3 https://packages.cloud.google.com/apt/doc/apt-key.gpg -o /etc/apt/keyrings/google-cloud.asc
  chmod 0644 /etc/apt/keyrings/google-cloud.asc
  printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/google-cloud.asc] https://packages.cloud.google.com/apt cloud-sdk main' > /etc/apt/sources.list.d/google-cloud.list
  apt-get -o APT::Update::Error-Mode=any update
  apt-get install -y --no-install-recommends google-cloud-cli
  install_docker
  gcloud auth configure-docker "$REGISTRY_HOST" --quiet
  ensure_network
  create_env "$role"
}

prepare_data_disk() {
  : "${DATA_DEVICE:?Set DATA_DEVICE to the attached data disk device path.}"
  local filesystem uuid mounted
  apt-get -o APT::Update::Error-Mode=any update
  apt-get install -y --no-install-recommends e2fsprogs util-linux
  [[ -b "$DATA_DEVICE" ]] || fail "Data disk is not attached: $DATA_DEVICE"
  if mountpoint -q "$DATA_MOUNT"; then
    mounted=$(findmnt -n -o MAJ:MIN --target "$DATA_MOUNT")
    [[ "$mounted" == "$(lsblk -dn -o MAJ:MIN "$DATA_DEVICE")" ]] || fail "A different disk is mounted at $DATA_MOUNT."
    return
  fi
  [[ -z "$(lsblk -n -o MOUNTPOINTS "$DATA_DEVICE" | tr -d '[:space:]')" ]] || fail "Data disk is already mounted elsewhere."
  filesystem=$(lsblk -dn -o FSTYPE "$DATA_DEVICE")
  if [[ -z "$filesystem" ]]; then
    [[ $(lsblk -nr -o NAME "$DATA_DEVICE" | wc -l) -eq 1 && -z "$(wipefs -n --noheadings "$DATA_DEVICE")" ]] ||
      fail "Refusing to format a disk containing partitions or signatures."
    mkfs.ext4 "$DATA_DEVICE"
    filesystem=ext4
  fi
  [[ "$filesystem" == ext4 ]] || fail "Expected an ext4 data disk; got $filesystem."
  uuid=$(blkid -s UUID -o value "$DATA_DEVICE")
  install -d -m 0755 "$DATA_MOUNT"
  if ! findmnt --fstab --mountpoint "$DATA_MOUNT" >/dev/null; then
    printf 'UUID=%s %s ext4 defaults,nofail 0 2\n' "$uuid" "$DATA_MOUNT" >> /etc/fstab
  else
    [[ $(findmnt --fstab -n -o SOURCE --mountpoint "$DATA_MOUNT") == "UUID=$uuid" ]] || fail "Conflicting fstab entry for $DATA_MOUNT."
  fi
  mount "$DATA_MOUNT"
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

DB_HOST=${DB_HOST:-${DB_IP:-}}
REDIS_HOST=${REDIS_HOST:-$DB_HOST}
RABBITMQ_HOST=${RABBITMQ_HOST:-$DB_HOST}
