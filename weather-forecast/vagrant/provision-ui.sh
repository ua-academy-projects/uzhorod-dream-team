#!/usr/bin/env bash
source /home/vagrant/weather-staging/common.sh || exit 1

configure_ssh
require_templates nginx.conf

history_ip=${1:?History IP is required}

apt-get install -y nginx
install -d -m 755 /var/www/weather-forecast
rsync -a "$stage/ui/" /var/www/weather-forecast/
find /var/www/weather-forecast -type d -exec chmod 755 {} +
find /var/www/weather-forecast -type f -exec chmod 644 {} +
install_template nginx.conf /etc/nginx/sites-available/default
nginx -t
systemctl enable nginx
systemctl restart nginx
