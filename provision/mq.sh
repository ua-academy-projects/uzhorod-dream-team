#!/usr/bin/env bash
# RabbitMQ (alternative queue backend) and Redis (fetcher cache). The script is idempotent.
# Variables from the Vagrantfile (urlencoded), all taken from deploy/queue.env: RABBIT_USER, RABBIT_PASS, RABBIT_VHOST (from RABBITMQ_URL),
# REDIS_PASSWORD (from REDIS_URL).
set -euo pipefail

LISTEN_IP=10.10.0.30

urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

user=$(urldecode "${RABBIT_USER:?RABBIT_USER is not set: RABBITMQ_URL is required in deploy/queue.env}")
pass=$(urldecode "${RABBIT_PASS:?}")
vhost=$(urldecode "${RABBIT_VHOST:-%2f}")
redis_pass=$(urldecode "${REDIS_PASSWORD:?REDIS_PASSWORD is not set: REDIS_URL is required in deploy/queue.env}")

DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rabbitmq-server redis-server redis-tools

# --- RabbitMQ: listen on the private address; the VM has little memory
cat >/etc/rabbitmq/rabbitmq.conf <<CONF
listeners.tcp.1 = 127.0.0.1:5672
listeners.tcp.2 = $LISTEN_IP:5672
vm_memory_high_watermark.absolute = 400MB
CONF
systemctl enable rabbitmq-server
systemctl restart rabbitmq-server
rabbitmqctl await_startup >/dev/null

if rabbitmqctl -q --no-table-headers list_users | cut -f1 | grep -qxF "$user"; then
  rabbitmqctl -q change_password "$user" "$pass" >/dev/null
else
  rabbitmqctl -q add_user "$user" "$pass" >/dev/null
fi
rabbitmqctl -q --no-table-headers list_vhosts | grep -qxF "$vhost" || rabbitmqctl -q add_vhost "$vhost" >/dev/null
rabbitmqctl -q set_permissions -p "$vhost" "$user" '.*' '.*' '.*' >/dev/null
# guest is only reachable from localhost anyway, but there is no need to keep the extra user
rabbitmqctl -q --no-table-headers list_users | cut -f1 | grep -qxF guest && rabbitmqctl -q delete_user guest >/dev/null || true

# --- Redis: this is a cache, so no persistence and LRU eviction
conf=/etc/redis/redis.conf
sed -i '/^# BEGIN reload$/,/^# END reload$/d' "$conf"
esc=${redis_pass//\\/\\\\}; esc=${esc//\"/\\\"}
cat >>"$conf" <<CONF
# BEGIN reload
bind 127.0.0.1 -::1 $LISTEN_IP
requirepass "$esc"
maxmemory 128mb
maxmemory-policy allkeys-lru
save ""
appendonly no
# END reload
CONF
systemctl enable redis-server
systemctl restart redis-server
