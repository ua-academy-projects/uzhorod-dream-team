#!/usr/bin/env bash
# nginx serving the static frontend (deploy/frontend.sh uploads the files). The script is idempotent.
set -euo pipefail

DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx

install -d -m755 /var/www/frontend
rm -f /etc/nginx/sites-enabled/default

cat >/etc/nginx/conf.d/frontend.conf <<'CONF'
server {
  listen 80 default_server;
  root /var/www/frontend;
  index index.html;
  location / { try_files $uri $uri/ =404; }
}
CONF

nginx -t
systemctl enable nginx
systemctl reload nginx || systemctl restart nginx
