#!/usr/bin/env bash
source /home/vagrant/weather-staging/common.sh || exit 1

configure_ssh

load_secrets
candidate=''
trap '[[ -z ${candidate:-} ]] || rm -f -- "$candidate"; rm -f -- "$stage/secrets.env"' EXIT

check_rabbitmq_url

candidate=$(mktemp "$config/fetcher.env.XXXXXX")
printf 'RABBITMQ_URL=%s\n' "$RABBITMQ_URL" > "$candidate"
chmod 600 "$candidate"
mv -f "$candidate" "$config/fetcher.env"
candidate=''

docker build -f "$stage/fetcher/Dockerfile" -t weather-fetcher:dev "$stage/fetcher"

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
