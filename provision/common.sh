#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ENV_DIR=/etc/weather

base_setup() {
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl
}

install_docker() {
  if ! command -v docker >/dev/null; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  fi
  local conf
  conf=$(mktemp)
  cat > "$conf" <<'JSON'
{
  "log-driver": "local",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
JSON
  if ! cmp -s "$conf" /etc/docker/daemon.json; then
    install -m 0644 "$conf" /etc/docker/daemon.json
    systemctl restart docker
  fi
  rm -f "$conf"
  systemctl enable --now docker
  usermod -aG docker vagrant
  install -d -m 0750 -o root -g docker "$ENV_DIR"
}

write_env() {
  install -m 0640 -o root -g docker /dev/stdin "$ENV_DIR/$1.env"
}

write_conf() {
  local path=$ENV_DIR/$1 mode=$2 owner=${3:-root}
  install -d -m 0750 -o root -g docker "$(dirname "$path")"
  install -m "$mode" -o "$owner" -g docker /dev/stdin "$path"
}

build_image() {
  local attempt
  for attempt in 1 2 3; do
    docker build -t "weather/$1" -f "/vagrant/$1/Dockerfile" /vagrant && break
    [ "$attempt" -lt 3 ] || return 1
    echo "build of weather/$1 failed (attempt $attempt/3), retrying in 10s" >&2
    sleep 10
  done
  docker image prune -f >/dev/null
}

ensure_network() {
  docker network inspect "$1" >/dev/null 2>&1 || docker network create "$1" >/dev/null
}

run_container() {
  local name=$1
  shift
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --restart unless-stopped --env-file "$ENV_DIR/$name.env" "$@" >/dev/null
  echo "started container $name"
}
