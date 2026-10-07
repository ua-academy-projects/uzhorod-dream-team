#!/usr/bin/env bash

validate_redis_password() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{32,}$ && "$1" != *change_me* && "$1" != *your_redis_password* ]] || {
    echo "Redis password must contain at least 32 unquoted letters, digits, underscores or hyphens, and cannot be a placeholder." >&2
    return 1
  }
}

wait_redis() {
  local host=$1 port=$2 password=$3 deadline=$((SECONDS + 30)) response remaining
  while (( SECONDS < deadline )); do
    remaining=$((deadline - SECONDS))
    (( remaining > 3 )) && remaining=3
    response=$(REDISCLI_AUTH="$password" timeout "${remaining}s" redis-cli -h "$host" -p "$port" PING 2>/dev/null) || response=""
    if [[ "$response" == "PONG" ]]; then
      return 0
    fi
    if (( SECONDS < deadline )); then
      sleep 1
    fi
  done
  echo "Timed out waiting for authenticated Redis at $host:$port. Check redis-server logs and configuration." >&2
  return 1
}

configure_redis() {
  local bind_addresses=$1 port=$2 password=$3 changed=false
  validate_redis_password "$password"
  REDIS_CONFIG_TEMP=$(mktemp)
  REDIS_MAIN_TEMP=$(mktemp)
  cat > "$REDIS_CONFIG_TEMP" <<REDIS
bind $bind_addresses
port $port
protected-mode yes
requirepass $password
dir /var/lib/redis
appendonly yes
appendfsync everysec
save ""
maxmemory 128mb
maxmemory-policy allkeys-lru
REDIS

  if ! cmp -s "$REDIS_CONFIG_TEMP" /etc/redis/kyiv-air.conf; then
    install -o root -g redis -m 0640 "$REDIS_CONFIG_TEMP" /etc/redis/kyiv-air.conf
    changed=true
  fi
  awk '
    $0 != "include /etc/redis/kyiv-air.conf" { print }
    END { print "include /etc/redis/kyiv-air.conf" }
  ' /etc/redis/redis.conf > "$REDIS_MAIN_TEMP"
  if ! cmp -s "$REDIS_MAIN_TEMP" /etc/redis/redis.conf; then
    install -o root -g redis -m 0640 "$REDIS_MAIN_TEMP" /etc/redis/redis.conf
    changed=true
  fi
  chown root:redis /etc/redis/kyiv-air.conf /etc/redis/redis.conf
  chmod 0640 /etc/redis/kyiv-air.conf /etc/redis/redis.conf

  systemctl enable redis-server.service
  if [[ "$changed" == true ]]; then
    systemctl restart redis-server.service
  else
    systemctl start redis-server.service
  fi
  wait_redis 127.0.0.1 "$port" "$password"
  rm -f "$REDIS_CONFIG_TEMP" "$REDIS_MAIN_TEMP"
  REDIS_CONFIG_TEMP=""
  REDIS_MAIN_TEMP=""
}
