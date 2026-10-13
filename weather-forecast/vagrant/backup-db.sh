#!/usr/bin/env bash
set -euo pipefail
umask 077

stage=/home/vagrant/weather-staging
backup=$stage/weather_history.auto.dump
trap 'rm -f -- "$backup.partial"' EXIT

if command -v docker >/dev/null && docker container inspect weather-postgres >/dev/null 2>&1; then
  docker start weather-postgres >/dev/null
  for attempt in {1..60}; do
    if docker exec weather-postgres pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then break; fi
    sleep 2
  done
  initialized=$(docker exec weather-postgres psql -X -U postgres -d weather_history \
    -Atqc "SELECT to_regclass('public.weather_snapshots') IS NOT NULL;")
  if [[ "$initialized" != t ]]; then
    native_dump=/etc/weather-forecast/backups/native-weather-history.dump
    if [[ -s "$native_dump" ]]; then
      cp "$native_dump" "$backup.partial"
    else
      exit 0
    fi
  else
    docker exec weather-postgres pg_dump --username=postgres \
      --format=custom --dbname=weather_history > "$backup.partial"
  fi
elif [[ -f /var/lib/postgresql/18/main/PG_VERSION ]]; then
  systemctl start postgresql@18-main
  sudo -u postgres /usr/lib/postgresql/18/bin/pg_dump \
    --format=custom --dbname=weather_history > "$backup.partial"
else
  rm -f -- "$backup"
  exit 0
fi

mv -f "$backup.partial" "$backup"
chown vagrant:vagrant "$backup"
chmod 600 "$backup"
