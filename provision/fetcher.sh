#!/usr/bin/env bash
source /vagrant/provision/common.sh
base_setup
: "${RABBITMQ_PASSWORD:?}" "${DB_IP:?}" "${RABBITMQ_PORT:?}"

GO_VERSION=${GO_VERSION:-1.22.12}
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go$GO_VERSION"; then
  curl -fsSL "https://go.dev/dl/go$GO_VERSION.linux-$(dpkg --print-architecture).tar.gz" | tar -C /usr/local -xz
fi

sync_src fetcher
sudo -u weather env HOME=/tmp GOCACHE=/tmp/gocache PATH="$PATH:/usr/local/go/bin" \
  bash -c "cd $APP_DIR/fetcher && go build -o bin/fetcher ./cmd/fetcher"

write_env weather-fetcher <<ENVF
AMQP_URL=amqp://weather:${RABBITMQ_PASSWORD}@${DB_IP}:${RABBITMQ_PORT}/weather
OPEN_METEO_BASE_URL=https://api.open-meteo.com/v1/forecast
ENVF
install_unit weather-fetcher "$APP_DIR/fetcher" "$APP_DIR/fetcher/bin/fetcher" "Weather Fetcher"
