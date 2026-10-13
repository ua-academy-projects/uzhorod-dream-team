#!/usr/bin/env bash
source /home/vagrant/weather-staging/common.sh || exit 1

configure_ssh
require_templates weather.service

db_ip=${1:?DB IP is required}

load_secrets
check_database_password
check_rabbitmq_url

if ! grep -q '^REDIS_PASSWORD=' "$config/history.env" 2>/dev/null; then
  [[ -n ${REDIS_PASSWORD:-} ]] || { echo 'Set REDIS_PASSWORD in secrets.env to the existing Redis password'; exit 1; }
fi
prepare_app_user
curl -fsSL https://go.dev/dl/go1.27.1.linux-amd64.tar.gz -o /tmp/weather-go.tar.gz
echo '63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445  /tmp/weather-go.tar.gz' | sha256sum -c -
tar -xzf /tmp/weather-go.tar.gz -C /usr/local
copy_app_sources history "bin/"
install -d -o weather -g weather "$app/history/bin"
cd "$app/history"
sudo -u weather env GOPATH=/var/lib/weather/go GOCACHE=/var/lib/weather/go-cache /usr/local/go/bin/go build -buildvcs=false -o bin/history.new .
mv bin/history.new bin/history
if [[ ! -f "$config/history.env" ]]; then
  cat > "$config/history.env" <<EOF
DATABASE_URL=postgres://weather_app:$WEATHER_DB_PASSWORD@${db_ip}:5432/weather_history?sslmode=disable
COLLECT_INTERVAL=15m
TEMPERATURE_SYNC_INTERVAL=1h
TEMPERATURE_HISTORY_DAYS=30
HISTORY_ADDR=0.0.0.0:8002
HISTORY_SERVE_UI=false
EOF
fi
sed -i '/^FETCHER_URL=/d' "$config/history.env"
add_setting "$config/history.env" RABBITMQ_URL "$RABBITMQ_URL"
add_setting "$config/history.env" REDIS_ADDR "${REDIS_ADDR:-${db_ip}:6379}"
add_setting "$config/history.env" REDIS_PASSWORD "${REDIS_PASSWORD:-}"
add_setting "$config/history.env" SESSION_COOKIE_SECURE "${SESSION_COOKIE_SECURE:-false}"
add_setting "$config/history.env" JOB_TIMEOUT 120s
add_setting "$config/history.env" CITY_NAME "${CITY_NAME:-Uzhhorod}"
add_setting "$config/history.env" CITY_LATITUDE "${CITY_LATITUDE:-48.6167}"
add_setting "$config/history.env" CITY_LONGITUDE "${CITY_LONGITUDE:-22.3}"
install_app_service history "$app/history" "$app/history/bin/history"
