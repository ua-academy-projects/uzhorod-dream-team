#!/usr/bin/env bash
source /vagrant/provision/common.sh
base_setup
: "${HISTORY_IP:?}" "${HISTORY_PORT:?}" "${FRONTEND_PORT:?}"
install_node

sync_src frontend
sudo -u weather bash -c "cd $APP_DIR/frontend && npm install --no-audit --no-fund && npm run build"

write_env weather-frontend <<ENVF
VITE_PROXY_TARGET=http://${HISTORY_IP}:${HISTORY_PORT}
ENVF
install_unit weather-frontend "$APP_DIR/frontend" \
  "$APP_DIR/frontend/node_modules/.bin/vite preview --host 0.0.0.0 --port $FRONTEND_PORT --strictPort" "Weather Frontend"
