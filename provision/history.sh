#!/usr/bin/env bash
source /vagrant/provision/common.sh
base_setup
: "${POSTGRES_PASSWORD:?}" "${REDIS_PASSWORD:?}" "${RABBITMQ_PASSWORD:?}" "${DB_IP:?}" "${HISTORY_IP:?}"
: "${HISTORY_PORT:?}" "${POSTGRES_PORT:?}" "${REDIS_PORT:?}" "${RABBITMQ_PORT:?}"
install_node

for svc in history scheduler; do
  sync_src "$svc"
  sudo -u weather bash -c "cd $APP_DIR/$svc && npm install --omit=dev --no-audit --no-fund"
done

write_env weather-history <<ENVF
PORT=${HISTORY_PORT}
DATABASE_URL=postgres://postgres:${POSTGRES_PASSWORD}@${DB_IP}:${POSTGRES_PORT}/${POSTGRES_DB:-weather}
AMQP_URL=amqp://weather:${RABBITMQ_PASSWORD}@${DB_IP}:${RABBITMQ_PORT}/weather
REDIS_URL=redis://:${REDIS_PASSWORD}@${DB_IP}:${REDIS_PORT}
ENVF
write_env weather-scheduler <<ENVF
HISTORY_SERVICE_URL=http://${HISTORY_IP}:${HISTORY_PORT}
CRON_SCHEDULE=${CRON_SCHEDULE:-*/15 * * * *}
ENVF

install_unit weather-history   "$APP_DIR/history"   "/usr/bin/node src/server.js" "Weather History"
install_unit weather-scheduler "$APP_DIR/scheduler" "/usr/bin/node index.js"      "Weather Scheduler"
