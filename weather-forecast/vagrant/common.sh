#!/usr/bin/env bash
set -euo pipefail
umask 022

stage=/home/vagrant/weather-staging
app=/opt/weather-forecast
config=/etc/weather-forecast
templates=$stage/templates
systemd_dir=/etc/systemd/system

load_secrets() {
  [[ -f "$stage/secrets.env" ]] || { echo 'secrets.env is required'; return 1; }
  chmod 600 "$stage/secrets.env"
  source "$stage/secrets.env"
}

check_database_password() {
  [[ ${WEATHER_DB_PASSWORD:-} =~ ^[a-f0-9]{48}$ ]] || { echo 'WEATHER_DB_PASSWORD must contain 48 hexadecimal characters'; return 1; }
}

check_rabbitmq_url() {
  [[ ${RABBITMQ_URL:-} == amqp://* || ${RABBITMQ_URL:-} == amqps://* ]] || { echo 'Set RABBITMQ_URL in secrets.env'; return 1; }
  [[ "$RABBITMQ_URL" != *$'\n'* && "$RABBITMQ_URL" != *'"'* && "$RABBITMQ_URL" != *'\'* ]] || { echo 'URL-encode special characters in RABBITMQ_URL'; return 1; }
}

add_setting() {
  local file=$1 key=$2 value=$3
  if ! grep -q "^${key}=" "$file"; then
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || { echo "Invalid multiline setting: $key"; return 1; }
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s="%s"\n' "$key" "$value" >> "$file"
  fi
}

prepare_app_user() {
  apt-get install -y build-essential
  if ! id weather >/dev/null 2>&1; then
    useradd --system --create-home --home-dir /var/lib/weather weather
  fi
  install -d -m 755 -o weather -g weather "$app"
}

copy_app_sources() {
  local name=$1 exclude=$2
  rsync -a --chown=weather:weather --exclude="$exclude" "$stage/$name/" "$app/$name/"
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

install_app_service() {
  local service_name=$1 working_directory=$2 start_command=$3
  chmod 600 "$config/$service_name.env"
  install_template weather.service "$systemd_dir/weather-$service_name.service"
  systemctl daemon-reload
  systemctl enable "weather-$service_name"
  systemctl restart "weather-$service_name"
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

save_broker_config() {
  local file=$1 candidate=$2 group=$3
  broker_config_changed=false
  if ! cmp -s "$file" "$candidate"; then
    if [[ -f "$file" && ! -f "$file.weather-backup" ]]; then
      install -m 600 -o root -g root "$file" "$file.weather-backup"
    fi
    install -m 640 -o root -g "$group" "$candidate" "$file"
    broker_config_changed=true
  fi
  rm -f -- "$candidate"
}

configure_redis() {
  local file=${1:-/etc/redis/redis.conf} candidate password reply check_address
  [[ -f "$file" ]] || { echo 'redis.conf is missing'; return 1; }
  if grep -Eq '^[[:space:]]*(include|aclfile|user)[[:space:]]' "$file"; then
    echo 'Custom Redis includes/ACLs detected; configure them manually to preserve authentication'; return 1;
  fi
  systemctl enable --now redis-server
  local has_password=false
  if awk '$1 == "requirepass" && NF > 1 && $2 != "\"\"" && $2 != "\047\047" { found=1 } END { exit !found }' "$file"; then
    has_password=true
    check_address=${db_ip}
    if ! grep -Eq '^[[:space:]]*bind[[:space:]]' "$file" || grep -Eq '^[[:space:]]*bind[[:space:]].*127\.0\.0\.1' "$file"; then
      check_address=127.0.0.1
    fi
    # Verify the existing password before changing any configuration.
    reply=$(REDISCLI_AUTH="$REDIS_PASSWORD" timeout 5 redis-cli -h "$check_address" --raw PING 2>/dev/null) || {
      echo 'Could not check existing Redis authentication; configuration kept unchanged'; return 1;
    }
    [[ "$reply" == PONG ]] || { echo 'Redis password mismatch; existing password kept unchanged'; return 1; }
  fi
  candidate=$(mktemp "${file}.weather.XXXXXX")
  awk '$1 != "bind" && $1 != "port"' "$file" > "$candidate"
  if [[ "$has_password" == false ]]; then
    sed -i '/^[[:space:]]*requirepass[[:space:]]/d' "$candidate"
    password=${REDIS_PASSWORD//\\/\\\\}
    password=${password//\"/\\\"}
    printf 'requirepass "%s"\n' "$password" >> "$candidate"
  fi
  render_template redis-network.conf >> "$candidate"
  save_broker_config "$file" "$candidate" redis
  if [[ "$broker_config_changed" == true ]]; then systemctl restart redis-server; fi
  reply=$(REDISCLI_AUTH="$REDIS_PASSWORD" timeout 5 redis-cli -h "${db_ip}" --raw PING 2>/dev/null) || {
    echo 'Redis private-interface connection failed'; return 1;
  }
  [[ "$reply" == PONG ]] || { echo 'Redis private-interface authentication failed'; return 1; }
  reply=$(env -u REDISCLI_AUTH timeout 5 redis-cli -h "${db_ip}" --raw PING 2>/dev/null) || true
  [[ "$reply" == *NOAUTH* ]] || { echo 'Redis must reject unauthenticated connections'; return 1; }
  echo 'Redis: private listener and password authentication are ready'
}

configure_rabbitmq() {
  local file=${1:-/etc/rabbitmq/rabbitmq.conf} candidate users vhosts permissions row name
  candidate=$(mktemp "${file}.weather.XXXXXX")
  if [[ -f "$file" ]]; then
    sed -E '/^[[:space:]]*listeners\.tcp(\.[[:alnum:]_]+)?[[:space:]]*=/d' "$file" > "$candidate"
  fi
  render_template rabbitmq.conf >> "$candidate"
  save_broker_config "$file" "$candidate" rabbitmq
  systemctl enable --now rabbitmq-server
  if [[ "$broker_config_changed" == true ]]; then systemctl restart rabbitmq-server; fi
  users=$(timeout 30 rabbitmqctl -q list_users --no-table-headers) || { echo 'Could not list RabbitMQ users'; return 1; }
  if ! printf '%s\n' "$users" | cut -f1 | grep -Fxq -- "$rabbit_user"; then
    timeout 30 rabbitmqctl -q add_user "$rabbit_user" "$rabbit_password" >/dev/null 2>&1 || { echo 'Could not create RabbitMQ user'; return 1; }
  fi
  # Never change the password of an existing user.
  timeout 30 rabbitmqctl -q authenticate_user "$rabbit_user" "$rabbit_password" >/dev/null 2>&1 || {
    echo 'RabbitMQ authentication failed; existing password kept unchanged'; return 1;
  }
  vhosts=$(timeout 30 rabbitmqctl -q list_vhosts name --no-table-headers) || { echo 'Could not list RabbitMQ vhosts'; return 1; }
  if ! printf '%s\n' "$vhosts" | grep -Fxq -- "$rabbit_vhost"; then
    timeout 30 rabbitmqctl -q add_vhost "$rabbit_vhost" >/dev/null 2>&1 || { echo 'Could not create RabbitMQ vhost'; return 1; }
  fi
  permissions=$(timeout 30 rabbitmqctl -q list_permissions -p "$rabbit_vhost" --no-table-headers) || { echo 'Could not list RabbitMQ permissions'; return 1; }
  local existing='' configure='' write='' read='' needed='^(weather\.requests|weather\.responses|amq\.default)$'
  while IFS= read -r row; do
    name=${row%%$'\t'*}
    if [[ "$name" == "$rabbit_user" ]]; then existing=$row; break; fi
  done <<< "$permissions"
  if [[ -n "$existing" ]]; then
    configure=$(printf '%s' "$existing" | cut -f2)
    write=$(printf '%s' "$existing" | cut -f3)
    read=$(printf '%s' "$existing" | cut -f4)
  fi
  local key value changed=false
  for key in configure write read; do
    value=${!key}
    if [[ "$value" != '.*' && "$value" != *"$needed"* ]]; then
      if [[ -z "$value" ]]; then value=$needed; else value="($value)|($needed)"; fi
      printf -v "$key" '%s' "$value"
      changed=true
    fi
  done
  if [[ "$changed" == true ]]; then
    timeout 30 rabbitmqctl -q set_permissions -p "$rabbit_vhost" "$rabbit_user" "$configure" "$write" "$read" >/dev/null 2>&1 || { echo 'Could not grant RabbitMQ queue permissions'; return 1; }
  fi
  echo 'RabbitMQ: private listener, account, vhost and queue permissions are ready'
}

configure_ssh() {

  require_templates sshd_config ssh.socket.conf
  [[ ${WEATHER_SSH_PORT:-} =~ ^[0-9]+$ ]] &&
    (( WEATHER_SSH_PORT >= 1024 && WEATHER_SSH_PORT <= 65535 )) || {
    echo 'WEATHER_SSH_PORT must be between 1024 and 65535'; return 1;
  }

  [[ -s /home/vagrant/weather-staging/arch-key.pub ]] || {
    echo 'Arch public key is missing'; return 1;
  }

  install -d -m 700 -o vagrant -g vagrant /home/vagrant/.ssh

  install -m 600 -o vagrant -g vagrant \
    /home/vagrant/weather-staging/arch-key.pub \
    /home/vagrant/.ssh/arch-key.pub

  touch /home/vagrant/.ssh/authorized_keys

  if ! grep -qxF "$(cat /home/vagrant/.ssh/arch-key.pub)" \
    /home/vagrant/.ssh/authorized_keys; then
    cat /home/vagrant/.ssh/arch-key.pub >> /home/vagrant/.ssh/authorized_keys
  fi

  chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys
  chmod 600 /home/vagrant/.ssh/authorized_keys

  config_tmp=$(mktemp)
  if ! render_template sshd_config > "$config_tmp"; then
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
  if ! render_template ssh.socket.conf > "$socket_tmp"; then
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
