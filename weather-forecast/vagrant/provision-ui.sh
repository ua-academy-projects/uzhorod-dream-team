#!/usr/bin/env bash
source /home/vagrant/weather-staging/common.sh || exit 1

configure_ssh
require_templates nginx.conf

history_ip=${1:?History IP is required}

install_template nginx.conf "$config/nginx.conf"
docker build -f "$stage/ui/Dockerfile" -t weather-ui:dev "$stage/ui"
docker run --rm \
  --mount "type=bind,src=$config/nginx.conf,dst=/etc/nginx/conf.d/default.conf,readonly" \
  weather-ui:dev nginx -t

if [[ -f /lib/systemd/system/nginx.service ]]; then
  systemctl disable --now nginx.service
fi

remove_container weather-ui
docker run --detach \
  --name weather-ui \
  --restart unless-stopped \
  --log-driver local --log-opt max-size=10m --log-opt max-file=3 \
  --publish 80:80 \
  --mount "type=bind,src=$config/nginx.conf,dst=/etc/nginx/conf.d/default.conf,readonly" \
  weather-ui:dev
