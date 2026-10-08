#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SRC_DIR=/vagrant_src
APP_DIR=/opt/weather
ENV_DIR=/etc/weather

base_setup() {
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg rsync
  id weather >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin weather
  install -d -o weather -g weather "$APP_DIR"
  install -d -m 0750 -o root -g weather "$ENV_DIR"
}

install_node() {
  command -v node >/dev/null && return
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y -qq nodejs
}

sync_src() {
  rsync -a --delete --exclude node_modules --exclude .env --exclude bin --exclude dist \
    "$SRC_DIR/$1/" "$APP_DIR/$1/"
  chown -R weather:weather "$APP_DIR/$1"
}

write_env() {
  install -m 0640 -o root -g weather /dev/stdin "$ENV_DIR/$1.env"
}

install_unit() {
  local name=$1 workdir=$2 exec=$3 desc=${4:-$1}
  cat > "/etc/systemd/system/$name.service" <<UNIT
[Unit]
Description=$desc
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
User=weather
WorkingDirectory=$workdir
EnvironmentFile=$ENV_DIR/$name.env
ExecStart=$exec
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable "$name.service"
  systemctl restart "$name.service"
}
