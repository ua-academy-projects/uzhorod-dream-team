#!/usr/bin/env bash

validate_rabbitmq_password() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{32,}$ && "$1" != *change_me* && "$1" != *your_rabbitmq_password* ]] || {
    echo "RabbitMQ password must contain at least 32 unquoted letters, digits, underscores or hyphens, and cannot be a placeholder." >&2
    return 1
  }
}

install_rabbitmq() {
  apt-get install -y --no-install-recommends ca-certificates curl gnupg
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL --retry 3 https://keys.openpgp.org/vks/v1/by-fingerprint/0A9AF2115F4687BD29803A206B73A36E6026DFCA |
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/rabbitmq.gpg
  chmod 0644 /etc/apt/keyrings/rabbitmq.gpg

  cat > /etc/apt/sources.list.d/rabbitmq.list <<'APT'
deb [arch=amd64 signed-by=/etc/apt/keyrings/rabbitmq.gpg] https://deb1.rabbitmq.com/rabbitmq-erlang/ubuntu/noble noble main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rabbitmq.gpg] https://deb2.rabbitmq.com/rabbitmq-erlang/ubuntu/noble noble main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rabbitmq.gpg] https://deb1.rabbitmq.com/rabbitmq-server/ubuntu/noble noble main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rabbitmq.gpg] https://deb2.rabbitmq.com/rabbitmq-server/ubuntu/noble noble main
APT

  cat > /etc/apt/preferences.d/rabbitmq <<'APT'
Package: rabbitmq-server
Pin: version 4.3.*
Pin-Priority: 700

Package: rabbitmq-server
Pin: version *
Pin-Priority: -1

Package: erlang*
Pin: version 1:27.*
Pin-Priority: 700

Package: erlang*
Pin: version *
Pin-Priority: -1
APT

  apt-get update
  apt-get install -y --no-install-recommends rabbitmq-server
  [[ $(dpkg-query -W -f='${Version}' rabbitmq-server) == 4.3.* &&
     $(dpkg-query -W -f='${Version}' erlang-base) == 1:27.* ]] || {
    echo "Expected RabbitMQ 4.3.x and Erlang 27.x from Team RabbitMQ repositories." >&2
    return 1
  }
}

wait_rabbitmq() {
  local port=$1 ready_timeout=$2 deadline remaining
  deadline=$((SECONDS + ready_timeout))
  while (( SECONDS < deadline )); do
    remaining=$((deadline - SECONDS))
    (( remaining > 10 )) && remaining=10
    if timeout "${remaining}s" rabbitmq-diagnostics -q check_running >/dev/null 2>&1 &&
       timeout "${remaining}s" rabbitmq-diagnostics -q check_port_listener "$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for RabbitMQ on port $port. Check rabbitmq-server.service logs." >&2
  return 1
}

configure_rabbitmq() {
  local bind_addresses=$1 port=$2 password=$3 ready_timeout=$4 changed=false epmd_changed=false index=1 address
  local -a addresses
  validate_rabbitmq_password "$password"
  read -r -a addresses <<< "$bind_addresses"
  RABBITMQ_CONFIG_TEMP=$(mktemp)
  for address in "${addresses[@]}"; do
    printf 'listeners.tcp.%s = %s:%s\n' "$index" "$address" "$port" >> "$RABBITMQ_CONFIG_TEMP"
    index=$((index + 1))
  done
  cat >> "$RABBITMQ_CONFIG_TEMP" <<'CONF'
management.tcp.ip = 127.0.0.1
management.tcp.port = 15672
distribution.listener.interface = 127.0.0.1
vm_memory_high_watermark.absolute = 512MB
CONF

  if ! cmp -s "$RABBITMQ_CONFIG_TEMP" /etc/rabbitmq/rabbitmq.conf; then
    install -o root -g rabbitmq -m 0640 "$RABBITMQ_CONFIG_TEMP" /etc/rabbitmq/rabbitmq.conf
    changed=true
  fi
  RABBITMQ_ENV_TEMP=$(mktemp)
  printf 'NODENAME=rabbit@localhost\nexport ERL_EPMD_ADDRESS=127.0.0.1\n' > "$RABBITMQ_ENV_TEMP"
  if ! cmp -s "$RABBITMQ_ENV_TEMP" /etc/rabbitmq/rabbitmq-env.conf; then
    install -o root -g rabbitmq -m 0640 "$RABBITMQ_ENV_TEMP" /etc/rabbitmq/rabbitmq-env.conf
    changed=true
  fi
  RABBITMQ_SOCKET_TEMP=$(mktemp)
  cat > "$RABBITMQ_SOCKET_TEMP" <<'UNIT'
[Socket]
ListenStream=
ListenStream=127.0.0.1:4369
UNIT
  install -d -m 0755 /etc/systemd/system/epmd.socket.d
  if ! cmp -s "$RABBITMQ_SOCKET_TEMP" /etc/systemd/system/epmd.socket.d/kyiv-air.conf; then
    install -m 0644 "$RABBITMQ_SOCKET_TEMP" /etc/systemd/system/epmd.socket.d/kyiv-air.conf
    changed=true
    epmd_changed=true
  fi
  if ! rabbitmq-plugins list -m -e | grep -x rabbitmq_management >/dev/null; then
    rabbitmq-plugins enable --offline rabbitmq_management
    changed=true
  fi
  systemctl enable rabbitmq-server.service
  if [[ "$epmd_changed" == true ]]; then
    systemctl stop rabbitmq-server.service
    systemctl stop epmd.socket epmd.service
    systemctl daemon-reload
    systemctl start epmd.socket
  fi
  if [[ "$changed" == true ]]; then
    systemctl restart rabbitmq-server.service
  else
    systemctl start rabbitmq-server.service
  fi
  wait_rabbitmq "$port" "$ready_timeout"

  if ! rabbitmqctl -q list_vhosts name | grep -x kyiv-air >/dev/null; then
    rabbitmqctl -q add_vhost kyiv-air
  fi
  if rabbitmqctl -q list_users | awk '{print $1}' | grep -x kyiv_air >/dev/null; then
    if ! rabbitmqctl -q authenticate_user kyiv_air "$password" >/dev/null 2>&1; then
      rabbitmqctl -q change_password kyiv_air "$password" >/dev/null 2>&1 || {
        echo "Could not update RabbitMQ application credentials." >&2
        return 1
      }
    fi
  else
    rabbitmqctl -q add_user kyiv_air "$password" >/dev/null 2>&1 || {
      echo "Could not create the RabbitMQ application user." >&2
      return 1
    }
  fi
  rabbitmqctl -q set_permissions -p kyiv-air kyiv_air '.*' '.*' '.*'
  rabbitmqctl -q set_user_tags kyiv_air management
  rabbitmqctl -q authenticate_user kyiv_air "$password" >/dev/null 2>&1 || {
    echo "RabbitMQ application authentication failed." >&2
    return 1
  }
  rabbitmq-diagnostics -q check_local_alarms
  rm -f "$RABBITMQ_CONFIG_TEMP" "$RABBITMQ_ENV_TEMP" "$RABBITMQ_SOCKET_TEMP"
  RABBITMQ_CONFIG_TEMP=""
  RABBITMQ_ENV_TEMP=""
  RABBITMQ_SOCKET_TEMP=""
}
