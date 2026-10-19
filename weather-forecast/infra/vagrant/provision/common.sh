#!/usr/bin/env bash
set -euo pipefail
umask 022

stage=/home/vagrant/weather-staging
app=/opt/weather-forecast
config=/etc/weather-forecast
templates=$stage/templates
systemd_dir=/etc/systemd/system

remove_container() {
  if docker container inspect "$1" >/dev/null 2>&1; then
    docker stop --time 60 "$1" >/dev/null
    docker rm "$1" >/dev/null
  fi
}

wait_for_container() {
  local name=$1 attempt
  shift
  for attempt in {1..60}; do
    if docker exec "$name" "$@" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  docker logs --tail 30 "$name"
  echo "$name did not become ready" >&2
  return 1
}

load_secrets() {
  [[ -f "$stage/secrets.env" ]] || { echo 'secrets.env is required'; return 1; }
  chmod 600 "$stage/secrets.env"
  source "$stage/secrets.env"
}

check_backend() {
  WEATHER_BACKEND=${WEATHER_BACKEND:-rabbitmq_redis}
  [[ "$WEATHER_BACKEND" == rabbitmq_redis || "$WEATHER_BACKEND" == postgres ]] || {
    echo 'WEATHER_BACKEND must be rabbitmq_redis or postgres'; return 1;
  }
}

build_service_image() {
  local service=$1 image=${2:-weather-$1:dev}
  if [[ ${WEATHER_SKIP_BUILD:-0} == 1 ]]; then
    docker image inspect "$image" >/dev/null
  else
    docker build -f "$stage/$service/Dockerfile" -t "$image" "$stage/$service"
  fi
}

check_database_password() {
  [[ ${WEATHER_DB_PASSWORD:-} =~ ^[a-f0-9]{48}$ ]] || { echo 'WEATHER_DB_PASSWORD must contain 48 hexadecimal characters'; return 1; }
}

check_fetcher_database_password() {
  [[ ${WEATHER_FETCHER_DB_PASSWORD:-} =~ ^[a-f0-9]{48}$ ]] || {
    echo 'WEATHER_FETCHER_DB_PASSWORD must contain 48 hexadecimal characters'; return 1;
  }
}

check_rabbitmq_url() {
  [[ ${RABBITMQ_URL:-} == amqp://* || ${RABBITMQ_URL:-} == amqps://* ]] || { echo 'Set RABBITMQ_URL in secrets.env'; return 1; }
  [[ "$RABBITMQ_URL" != *$'\n'* && "$RABBITMQ_URL" != *'"'* && "$RABBITMQ_URL" != *'\'* ]] || { echo 'URL-encode special characters in RABBITMQ_URL'; return 1; }
}

require_templates() {
  local name
  for name in "$@"; do
    [[ -f "$templates/$name" ]] || { echo "Missing template: $templates/$name" >&2; return 1; }
  done
}

render_template() {
  local name=$1
  require_templates "$name" || return 1
  sed -e "s|@APP_DIR@|$app|g" \
      -e "s|@CONFIG_DIR@|$config|g" \
      -e "s|@DB_IP@|${db_ip:-}|g" \
      -e "s|@HISTORY_IP@|${history_ip:-}|g" \
      -e "s|@FETCHER_IP@|${fetcher_ip:-}|g" \
      -e "s|@SERVICE@|${service_name:-}|g" \
      -e "s|@PORT@|${WEATHER_SSH_PORT:-}|g" \
      -e "s|@WORKDIR@|${working_directory:-}|g" \
      -e "s|@EXEC_START@|${start_command:-}|g" "$templates/$name"
}

install_template() {
  local name=$1 destination=$2 candidate
  candidate=$(mktemp)
  if ! render_template "$name" > "$candidate"; then
    rm -f -- "$candidate"
    return 1
  fi
  install -m 644 -o root -g root "$candidate" "$destination"
  rm -f -- "$candidate"
}

decode_url_part() {
  local value=$1 remaining
  remaining=$(printf '%s' "$value" | sed -E 's/%[0-9a-fA-F]{2}//g')
  [[ "$remaining" != *%* && "$value" != *'\'* && ! "$value" =~ %(0[0-9a-fA-F]|1[0-9a-fA-F]|7[fF]) ]] || {
    echo 'Invalid URL encoding or control character in RABBITMQ_URL' >&2; return 1;
  }
  printf '%b' "${value//%/\\x}"
}

read_broker_settings() {
  local pattern='^amqp://([^:/@]+):([^/@]+)@([^/:]+)(:([0-9]+))?(/([^?#]*))?$'
  [[ "$RABBITMQ_URL" != *'?'* && "$RABBITMQ_URL" != *'#'* && "$RABBITMQ_URL" =~ $pattern ]] || {
    echo 'Use amqp://USER:PASSWORD@DB_IP:5672/VHOST with URL-encoded credentials'; return 1;
  }
  local username=${BASH_REMATCH[1]} password=${BASH_REMATCH[2]} address=${BASH_REMATCH[3]}
  local port=${BASH_REMATCH[5]} path=${BASH_REMATCH[6]} vhost=${BASH_REMATCH[7]}
  [[ "$address" == "${db_ip}" && ( -z "$port" || "$port" == 5672 ) ]] || {
    echo 'RABBITMQ_URL must point to the DB VM on port 5672'; return 1;
  }
  rabbit_user=$(decode_url_part "$username") || return 1
  rabbit_password=$(decode_url_part "$password") || return 1
  rabbit_vhost=/
  if [[ -n "$path" ]]; then rabbit_vhost=$(decode_url_part "$vhost") || return 1; fi
  [[ -n "$rabbit_user" && "$rabbit_user" != guest && "$rabbit_user" != -* && -n "$rabbit_password" && -n "$rabbit_vhost" && "$rabbit_vhost" != -* ]] || {
    echo 'Use a non-guest RabbitMQ user, a password and a nonempty vhost'; return 1;
  }
  [[ ${REDIS_ADDR:-${db_ip}:6379} == "${db_ip}:6379" ]] || {
    echo 'REDIS_ADDR must point to the DB VM on port 6379'; return 1;
  }
}

configure_ssh() {
  local ssh_template=${1:-ssh/bastion.conf}
  local ssh_user=${2:-vagrant} ssh_home

  ssh_home=$(getent passwd "$ssh_user" | cut -d: -f6)
  [[ -n "$ssh_home" ]] || { echo "SSH user does not exist: $ssh_user"; return 1; }

  require_templates "$ssh_template" ssh/socket.conf
  [[ ${WEATHER_SSH_PORT:-} =~ ^[0-9]+$ ]] &&
    (( WEATHER_SSH_PORT >= 1024 && WEATHER_SSH_PORT <= 65535 )) || {
    echo 'WEATHER_SSH_PORT must be between 1024 and 65535'; return 1;
  }

  [[ -s /home/vagrant/weather-staging/host-key.pub ]] || {
    echo 'Host public key is missing'; return 1;
  }

  install -d -m 700 -o "$ssh_user" -g "$ssh_user" "$ssh_home/.ssh"

  install -m 600 -o "$ssh_user" -g "$ssh_user" \
    /home/vagrant/weather-staging/host-key.pub \
    "$ssh_home/.ssh/host-key.pub"

  touch "$ssh_home/.ssh/authorized_keys"

  if ! grep -qxF "$(cat "$ssh_home/.ssh/host-key.pub")" \
    "$ssh_home/.ssh/authorized_keys"; then
    cat "$ssh_home/.ssh/host-key.pub" >> "$ssh_home/.ssh/authorized_keys"
  fi

  chown "$ssh_user:$ssh_user" "$ssh_home/.ssh/authorized_keys"
  chmod 600 "$ssh_home/.ssh/authorized_keys"

  config_tmp=$(mktemp)
  if ! render_template "$ssh_template" > "$config_tmp"; then
    rm -f "$config_tmp"
    return 1
  fi
  if ! sshd -t -f "$config_tmp"; then
    rm -f "$config_tmp"
    echo 'Invalid sshd_config'
    return 1
  fi
  install -m 644 -o root -g root "$config_tmp" /etc/ssh/sshd_config
  rm -f "$config_tmp"

  install -d -m 755 /etc/systemd/system/ssh.socket.d
  socket_tmp=$(mktemp)
  if ! render_template ssh/socket.conf > "$socket_tmp"; then
    rm -f "$socket_tmp"
    return 1
  fi
  install -m 644 -o root -g root \
    "$socket_tmp" /etc/systemd/system/ssh.socket.d/10-weather-ports.conf
  rm -f "$socket_tmp"

  systemctl daemon-reload

  if systemctl is-active --quiet ssh.socket; then
    systemctl restart ssh.socket ssh.service
  elif systemctl is-enabled --quiet ssh.socket; then
    systemctl enable --now ssh.socket
    systemctl restart ssh.service
  else
    systemctl restart ssh.service
  fi
}
