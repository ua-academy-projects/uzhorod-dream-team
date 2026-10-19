#!/usr/bin/env bash
source /home/vagrant/weather-staging/common.sh || exit 1

configure_ssh ssh/services.conf

db_ip=${1:?DB IP is required}

load_secrets
candidate=''
trap '[[ -z ${candidate:-} ]] || rm -f -- "$candidate"; rm -f -- "$stage/secrets.env"' EXIT

check_backend
if [[ "$WEATHER_BACKEND" == postgres ]]; then
  check_fetcher_database_password
else
  check_rabbitmq_url
fi

candidate=$(mktemp "$config/fetcher.env.XXXXXX")
printf 'WEATHER_BACKEND=%s\n' "$WEATHER_BACKEND" > "$candidate"
if [[ "$WEATHER_BACKEND" == postgres ]]; then
  printf 'DATABASE_URL=postgres://weather_fetcher:%s@%s:5432/weather_history?sslmode=disable\n' \
    "$WEATHER_FETCHER_DB_PASSWORD" "$db_ip" >> "$candidate"
else
  printf 'RABBITMQ_URL=%s\n' "$RABBITMQ_URL" >> "$candidate"
fi
chmod 600 "$candidate"
mv -f "$candidate" "$config/fetcher.env"
candidate=''

build_service_image fetcher

if [[ -f /etc/systemd/system/weather-fetcher.service ]]; then
  systemctl disable --now weather-fetcher.service
  rm -f /etc/systemd/system/weather-fetcher.service
  systemctl daemon-reload
fi

remove_container weather-fetcher

docker run --detach \
  --name weather-fetcher \
  --restart unless-stopped \
  --log-driver local --log-opt max-size=10m --log-opt max-file=3 \
  --env-file "$config/fetcher.env" \
  weather-fetcher:dev
