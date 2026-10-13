#!/usr/bin/env bash
source /home/vagrant/weather-staging/common.sh || exit 1

configure_ssh
require_templates weather.service

load_secrets
check_rabbitmq_url

apt-get install -y python3 python3-venv
prepare_app_user
copy_app_sources fetcher "__pycache__/"
sudo -u weather python3 -m venv "$app/.venv"
sudo -u weather "$app/.venv/bin/python" -m pip install -r "$app/fetcher/requirements.txt"
if [[ ! -f "$config/fetcher.env" ]]; then
  cat > "$config/fetcher.env" <<EOF
FETCHER_HOST=0.0.0.0
FETCHER_PORT=8001
CITY_NAME=Uzhhorod
CITY_LATITUDE=48.6167
CITY_LONGITUDE=22.3
OPEN_METEO_TIMEOUT_SECONDS=10
PYTHONUNBUFFERED=1
EOF
fi
add_setting "$config/fetcher.env" RABBITMQ_URL "$RABBITMQ_URL"
install_app_service fetcher "$app" "$app/.venv/bin/python -m fetcher"
