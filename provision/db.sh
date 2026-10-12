#!/usr/bin/env bash
source /tmp/weather-common.sh
: "${POSTGRES_PASSWORD:?}" "${REDIS_PASSWORD:?}" "${RABBITMQ_PASSWORD:?}" "${HISTORY_IP:?}"
: "${DB_IP:?}" "${POSTGRES_PORT:?}" "${REDIS_PORT:?}" "${RABBITMQ_PORT:?}" "${RABBITMQ_UI_PORT:?}"
base_setup
install_docker

write_env postgres <<ENVF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB:-weather}
ENVF
write_conf pg_hba.conf 0644 <<CONF
local all all trust
host all postgres ${HISTORY_IP}/32 scram-sha-256
CONF

write_env redis <<ENVF
REDISCLI_AUTH=${REDIS_PASSWORD}
ENVF
write_conf redis.conf 0640 999 <<CONF
bind 0.0.0.0
port 6379
protected-mode yes
requirepass ${REDIS_PASSWORD}
dir /data
appendonly yes
maxmemory 64mb
maxmemory-policy volatile-lru
CONF

write_env rabbitmq <<ENVF
RABBITMQ_DEFAULT_USER=weather
RABBITMQ_DEFAULT_PASS=${RABBITMQ_PASSWORD}
RABBITMQ_DEFAULT_VHOST=weather
RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS=+S 1:1 +sbwt none +sbwtdcpu none +sbwtdio none
ENVF
write_conf rabbitmq/20-weather.conf 0644 <<CONF
vm_memory_high_watermark.absolute = 256MiB
CONF
write_conf rabbitmq/enabled_plugins 0644 <<CONF
[rabbitmq_management,rabbitmq_tracing].
CONF
write_conf rabbitmq/advanced.config 0640 100 <<CONF
[{rabbitmq_tracing, [{username, <<"weather">>}, {password, <<"${RABBITMQ_PASSWORD}">>}]}].
CONF

run_container postgres \
  -p "$DB_IP:$POSTGRES_PORT:5432" -v pgdata:/var/lib/postgresql/data \
  -v "$ENV_DIR/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro" \
  --shm-size 128m --memory 320m --security-opt no-new-privileges \
  --health-cmd 'pg_isready -U postgres' --health-interval 10s \
  postgres:16-alpine postgres -c hba_file=/etc/postgresql/pg_hba.conf \
  -c shared_buffers=64MB -c effective_cache_size=192MB -c max_connections=30

run_container redis \
  -p "$DB_IP:$REDIS_PORT:6379" -v redisdata:/data \
  -v "$ENV_DIR/redis.conf:/usr/local/etc/redis/redis.conf:ro" \
  --user redis --read-only --cap-drop ALL --security-opt no-new-privileges --memory 96m \
  --health-cmd 'redis-cli ping' --health-interval 10s \
  redis:7-alpine redis-server /usr/local/etc/redis/redis.conf

run_container rabbitmq --hostname rabbitmq \
  -p "$DB_IP:$RABBITMQ_PORT:5672" -p "$DB_IP:$RABBITMQ_UI_PORT:15672" -v rabbitmqdata:/var/lib/rabbitmq \
  -v "$ENV_DIR/rabbitmq/20-weather.conf:/etc/rabbitmq/conf.d/20-weather.conf:ro" \
  -v "$ENV_DIR/rabbitmq/enabled_plugins:/etc/rabbitmq/enabled_plugins:ro" \
  -v "$ENV_DIR/rabbitmq/advanced.config:/etc/rabbitmq/advanced.config:ro" \
  --memory 384m --security-opt no-new-privileges \
  --health-cmd 'rabbitmq-diagnostics -q ping' --health-interval 30s \
  rabbitmq:4.1-management-alpine
