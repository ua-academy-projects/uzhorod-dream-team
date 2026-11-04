#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

(( EUID == 0 )) || fail "Run this script with sudo."
: "${PRIVATE_IP:?Set PRIVATE_IP in the startup environment.}"
DB_HOST=${DB_HOST:-$PRIVATE_IP}
REDIS_HOST=${REDIS_HOST:-$PRIVATE_IP}
RABBITMQ_HOST=${RABBITMQ_HOST:-$PRIVATE_IP}
DATA_MOUNT=${DATA_MOUNT:-/srv/kyiv-air-data}
[[ "$DATA_MOUNT" =~ ^/[A-Za-z0-9_/-]+$ ]] || fail "DATA_MOUNT must be an absolute path without spaces."
prepare_data_disk
prepare_runtime db

REDIS_PASSWORD=$(get_secret redis-password)
validate_password REDIS_PASSWORD "$REDIS_PASSWORD" 32
read_rabbitmq
install -d -m 0755 /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=%s\n' "$DATA_MOUNT" > /etc/systemd/system/docker.service.d/kyiv-air-data.conf
systemctl daemon-reload

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

redis_ports=(-p "$PRIVATE_IP:6379:6379" -p 127.0.0.1:6379:6379)
rabbit_ports=(-p "$PRIVATE_IP:5672:5672" -p 127.0.0.1:5672:5672)
docker pull "$REDIS_IMAGE"
docker pull "$RABBITMQ_IMAGE"

for service in redis rabbitmq; do
  if [[ "$service" == redis ]]; then image=$REDIS_IMAGE; else image=$RABBITMQ_IMAGE; fi
  docker run --rm --user root --entrypoint sh \
    --mount "type=bind,src=$DATA_MOUNT,dst=/data" "$image" -c \
    'mkdir -p "/data/$1" && chown "$1:$1" "/data/$1" && chmod 0700 "/data/$1"' sh "$service"
done

replace_container kyiv-air-redis "${redis_ports[@]}" \
  --mount "type=bind,src=$DATA_MOUNT/redis,dst=/data" -v "$CONFIG/redis.conf:/usr/local/etc/redis/redis.conf:ro" \
  "$REDIS_IMAGE" redis-server /usr/local/etc/redis/redis.conf
wait_command Redis docker run --rm --network "$NETWORK" --env-file "$CONFIG/redis-probe.env" \
  "$REDIS_IMAGE" sh -c '[ "$(redis-cli -h kyiv-air-redis PING)" = PONG ]'
replace_container kyiv-air-rabbitmq "${rabbit_ports[@]}" -p 127.0.0.1:15672:15672 \
  --hostname kyiv-air-rabbitmq --env-file "$CONFIG/rabbitmq.env" \
  --mount "type=bind,src=$DATA_MOUNT/rabbitmq,dst=/var/lib/rabbitmq" -v "$CONFIG/rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro" "$RABBITMQ_IMAGE"
wait_command RabbitMQ docker exec kyiv-air-rabbitmq rabbitmq-diagnostics -q check_running
docker exec kyiv-air-rabbitmq sh -c 'rabbitmqctl -q change_password kyiv_air "$RABBITMQ_DEFAULT_PASS" >/dev/null 2>&1' || fail "Could not update RabbitMQ credentials."
docker exec kyiv-air-rabbitmq rabbitmqctl -q set_permissions -p kyiv-air kyiv_air '.*' '.*' '.*'
docker exec kyiv-air-rabbitmq rabbitmqctl -q set_user_tags kyiv_air management
docker exec kyiv-air-rabbitmq sh -c 'rabbitmqctl -q authenticate_user kyiv_air "$RABBITMQ_DEFAULT_PASS" >/dev/null 2>&1' || fail "RabbitMQ authentication failed."
wait_command AMQP docker exec kyiv-air-rabbitmq rabbitmq-diagnostics -q check_port_listener 5672
