#!/usr/bin/env bash
source /home/vagrant/weather-staging/common.sh || exit 1

configure_ssh sshd-services.conf

db_ip=${1:?DB IP is required}
history_ip=${2:?History IP is required}

load_secrets
candidate=''
trap '[[ -z ${candidate:-} ]] || rm -f -- "$candidate"; rm -f -- "$stage/secrets.env"' EXIT

check_database_password
check_rabbitmq_url
[[ -n ${REDIS_PASSWORD:-} && ! "$REDIS_PASSWORD" =~ [[:cntrl:]] ]] || {
  echo 'Set a single-line REDIS_PASSWORD in secrets.env'; exit 1;
}
read_broker_settings

candidate=$(mktemp "$config/history.env.XXXXXX")
cat > "$candidate" <<EOF
DATABASE_URL=postgres://weather_app:${WEATHER_DB_PASSWORD}@${db_ip}:5432/weather_history?sslmode=disable
COLLECT_INTERVAL=15m
TEMPERATURE_SYNC_INTERVAL=1h
TEMPERATURE_HISTORY_DAYS=30
HISTORY_ADDR=0.0.0.0:8002
HISTORY_SERVE_UI=false
RABBITMQ_URL=${RABBITMQ_URL}
REDIS_ADDR=${REDIS_ADDR:-${db_ip}:6379}
REDIS_PASSWORD=${REDIS_PASSWORD}
SESSION_COOKIE_SECURE=${SESSION_COOKIE_SECURE:-false}
JOB_TIMEOUT=120s
CITY_NAME=${CITY_NAME:-Uzhhorod}
CITY_LATITUDE=${CITY_LATITUDE:-48.6167}
CITY_LONGITUDE=${CITY_LONGITUDE:-22.3}
EOF
chmod 600 "$candidate"
mv -f "$candidate" "$config/history.env"
candidate=''

docker build -f "$stage/history/Dockerfile" -t weather-history:dev "$stage/history"

if [[ -f /etc/systemd/system/weather-history.service ]]; then
  systemctl disable --now weather-history.service
  rm -f /etc/systemd/system/weather-history.service
  systemctl daemon-reload
fi

remove_container weather-history

docker run --detach \
  --name weather-history \
  --restart unless-stopped \
  --log-driver local --log-opt max-size=10m --log-opt max-file=3 \
  --env-file "$config/history.env" \
  --publish "${history_ip}:8002:8002" \
  weather-history:dev
