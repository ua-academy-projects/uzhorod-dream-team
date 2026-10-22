#!/usr/bin/env bash
# Provisioning of fetcher-vm, step "fetcher": the container of Fetcher with the settings
# of APP_MODE (app_mode in weather-vm.yml). The image is built before by the step
# "fetcher-image" (provision/fetcher-image.sh); this step does not build it.
#   rabbitmq - Fetcher takes requests from RabbitMQ in weather-vm;
#   postgres - Fetcher takes requests from the table weather_requests in PostgreSQL
#              (role weather_fetcher, see provision/db-mode.sh).
# Fetcher does not listen on any port. Running it again is safe: the container is created again.
set -euo pipefail

if [[ "${APP_MODE:-}" != "rabbitmq" && "${APP_MODE:-}" != "postgres" ]]; then
  echo "APP_MODE must be rabbitmq or postgres" >&2
  exit 1
fi
if [[ ! "${DB_IP:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "DB_IP must be an IPv4 address" >&2
  exit 1
fi
if [[ "$APP_MODE" == "rabbitmq" ]]; then
  for name in RABBITMQ_USER RABBITMQ_VHOST; do
    if [[ ! "${!name:-}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; then
      echo "$name must be lowercase letters, digits or _" >&2
      exit 1
    fi
  done
  if [[ ! "${RABBITMQ_PASSWORD:-}" =~ ^[A-Za-z0-9]{16,}$ ]]; then
    echo "RABBITMQ_PASSWORD must be at least 16 letters or digits" >&2
    exit 1
  fi
else
  if [[ ! "${WEATHER_DB_NAME:-}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; then
    echo "WEATHER_DB_NAME must be a lowercase PostgreSQL identifier" >&2
    exit 1
  fi
  if [[ ! "${FETCHER_DB_PASSWORD:-}" =~ ^[A-Za-z0-9]{16,}$ ]]; then
    echo "FETCHER_DB_PASSWORD must be at least 16 letters or digits" >&2
    exit 1
  fi
  if [[ ! "${QUEUE_POLL_INTERVAL_SECONDS:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "QUEUE_POLL_INTERVAL_SECONDS must be a positive whole number" >&2
    exit 1
  fi
fi

IMAGE=weather-fetcher:local
CONTAINER=weather-fetcher
# Settings with the password: outside the build folder, so they never get into the image.
ENV_FILE=/opt/weather-history/fetcher.env
# Fetcher before Docker (venv + systemd). Its unit file is kept for a rollback.
OLD_SERVICE=weather-fetcher.service
# Timeout of one Open-Meteo request and the lease of a request (mode postgres).
# The lease must be at least 4 x timeout + 10 s (Fetcher checks it at start, see config.py).
OPEN_METEO_TIMEOUT_SECONDS=10
QUEUE_LEASE_SECONDS=60

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Image $IMAGE not found: run the step fetcher-image first" >&2
  exit 1
fi

# Gives the work back to the old Fetcher, if it is still in this VM.
rollback() {
  docker rm --force "$CONTAINER" >/dev/null 2>&1 || true
  if [[ -n "$(systemctl list-unit-files "$OLD_SERVICE" --no-legend)" ]]; then
    systemctl enable --now "$OLD_SERVICE"
    echo "Rollback: the old $OLD_SERVICE is running again" >&2
  fi
  exit 1
}

# 1. Settings for the container: only what the mode needs. Only root can read the file
#    (docker run reads it as root). sslmode=require: the connection to PostgreSQL is encrypted.
mkdir -p /opt/weather-history
(
  umask 077
  cat > "$ENV_FILE" <<EOF
APP_MODE=$APP_MODE
CITY_NAME=Lviv
CITY_LATITUDE=49.84
CITY_LONGITUDE=24.03
OPEN_METEO_TIMEOUT_SECONDS=$OPEN_METEO_TIMEOUT_SECONDS
EOF
  if [[ "$APP_MODE" == "rabbitmq" ]]; then
    echo "AMQP_URL=amqp://$RABBITMQ_USER:$RABBITMQ_PASSWORD@$DB_IP:5672/$RABBITMQ_VHOST" >> "$ENV_FILE"
  else
    cat >> "$ENV_FILE" <<EOF
DATABASE_URL=postgresql://weather_fetcher:$FETCHER_DB_PASSWORD@$DB_IP:5432/$WEATHER_DB_NAME?sslmode=require&connect_timeout=10
QUEUE_POLL_INTERVAL_SECONDS=$QUEUE_POLL_INTERVAL_SECONDS
QUEUE_LEASE_SECONDS=$QUEUE_LEASE_SECONDS
EOF
  fi
)
chown root:root "$ENV_FILE"
chmod 0600 "$ENV_FILE"

# 2. Only one Fetcher at a time: the old systemd service is stopped before the container starts.
if [[ -n "$(systemctl list-unit-files "$OLD_SERVICE" --no-legend)" ]]; then
  systemctl disable --now "$OLD_SERVICE"
fi

# 3. The container from the previous provisioning is removed and created again.
#    --restart unless-stopped: Docker starts it again after a crash and after a VM reboot,
#      unless it was stopped by hand (docker stop).
#    No --publish: no ports are opened.
#    --log-opt: logs are kept in at most 3 files of 10 MB.
docker rm --force "$CONTAINER" >/dev/null 2>&1 || true
docker run --detach \
  --name "$CONTAINER" \
  --restart unless-stopped \
  --env-file "$ENV_FILE" \
  --log-opt max-size=10m --log-opt max-file=3 \
  "$IMAGE" >/dev/null

# 4. The container must still be running after 15 s and must not have been restarted:
#    otherwise Fetcher fails at start (wrong settings, no connection to RabbitMQ/PostgreSQL).
sleep 15
state=$(docker inspect --format '{{.State.Running}} {{.RestartCount}}' "$CONTAINER" 2>/dev/null || true)
if [[ "$state" != "true 0" ]]; then
  echo "Container $CONTAINER does not run (running, restarts: ${state:-none}). Last log lines:" >&2
  docker logs --tail 20 "$CONTAINER" >&2 || true
  rollback
fi
echo "Container $CONTAINER is running in mode $APP_MODE"
