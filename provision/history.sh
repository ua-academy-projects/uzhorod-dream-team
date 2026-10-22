#!/usr/bin/env bash
# Provisioning of history-vm, step "history": the container of History with the settings
# of APP_MODE (app_mode in weather-vm.yml). The image is built before by the step
# "history-image" (provision/history-image.sh); this step does not build it.
#   rabbitmq - History uses RabbitMQ (queues) and Redis (settings);
#   postgres - History uses only PostgreSQL (queue tables and settings).
# Running it again is safe: the container is created again.
set -euo pipefail

if [[ "${APP_MODE:-}" != "rabbitmq" && "${APP_MODE:-}" != "postgres" ]]; then
  echo "APP_MODE must be rabbitmq or postgres" >&2
  exit 1
fi
for name in WEATHER_DB_ROLE WEATHER_DB_NAME; do
  if [[ ! "${!name:-}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; then
    echo "$name must be a lowercase PostgreSQL identifier" >&2
    exit 1
  fi
done
if [[ ! "${WEATHER_DB_PASSWORD:-}" =~ ^[A-Za-z0-9]{16,}$ ]]; then
  echo "WEATHER_DB_PASSWORD must be at least 16 letters or digits" >&2
  exit 1
fi
if [[ ! "${DB_IP:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "DB_IP must be an IPv4 address" >&2
  exit 1
fi
# RabbitMQ and Redis settings are needed only in mode rabbitmq.
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
  if [[ ! "${REDIS_PASSWORD:-}" =~ ^[A-Za-z0-9]{16,}$ ]]; then
    echo "REDIS_PASSWORD must be at least 16 letters or digits" >&2
    exit 1
  fi
else
  if [[ ! "${QUEUE_POLL_INTERVAL_SECONDS:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "QUEUE_POLL_INTERVAL_SECONDS must be a positive whole number" >&2
    exit 1
  fi
fi

IMAGE=weather-history:local
CONTAINER=weather-history
# Settings with the passwords: outside the build context, so they never get into the image.
ENV_FILE=/opt/weather-history/history.env
# The user "nonroot" of the distroless image: it must be able to read ENV_FILE.
CONTAINER_UID=65532
# History before Docker (binary + systemd). Its unit file and binary are kept for a rollback.
OLD_SERVICE=weather-history.service

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Image $IMAGE not found: run the step history-image first" >&2
  exit 1
fi

# Gives the work back to the old History, if it is still in this VM.
rollback() {
  docker rm --force "$CONTAINER" >/dev/null 2>&1 || true
  if [[ -n "$(systemctl list-unit-files "$OLD_SERVICE" --no-legend)" ]]; then
    systemctl enable --now "$OLD_SERVICE"
    echo "Rollback: the old $OLD_SERVICE is running again" >&2
  fi
  exit 1
}

# 1. Settings for the container: only what the mode needs.
#    sslmode=require: the connection to PostgreSQL is encrypted.
#    0640 root:65532 — only root and the user of the container can read the file.
mkdir -p /opt/weather-history
(
  umask 077
  cat > "$ENV_FILE" <<EOF
APP_MODE=$APP_MODE
HISTORY_ADDR=0.0.0.0:8080
FETCH_INTERVAL=5m
DATABASE_URL=postgres://$WEATHER_DB_ROLE:$WEATHER_DB_PASSWORD@$DB_IP:5432/$WEATHER_DB_NAME?sslmode=require
EOF
  if [[ "$APP_MODE" == "rabbitmq" ]]; then
    cat >> "$ENV_FILE" <<EOF
AMQP_URL=amqp://$RABBITMQ_USER:$RABBITMQ_PASSWORD@$DB_IP:5672/$RABBITMQ_VHOST
REDIS_URL=redis://:$REDIS_PASSWORD@$DB_IP:6379/0
EOF
  else
    echo "QUEUE_POLL_INTERVAL=${QUEUE_POLL_INTERVAL_SECONDS}s" >> "$ENV_FILE"
  fi
)
chown "root:$CONTAINER_UID" "$ENV_FILE"
chmod 0640 "$ENV_FILE"

# 2. Only one History at a time (and port 8080 must be free):
#    the old systemd service is stopped before the container starts.
if [[ -n "$(systemctl list-unit-files "$OLD_SERVICE" --no-legend)" ]]; then
  systemctl disable --now "$OLD_SERVICE"
fi

# 3. The container from the previous provisioning is removed and created again.
#    --restart unless-stopped: Docker starts it again after a crash and after a VM reboot,
#      unless it was stopped by hand (docker stop).
#    --publish 8080:8080: port 8080 of the VM -> port 8080 of the container
#      (Vagrant forwards port 8080 of the VM to Windows 8081).
#    --volume ...:ro: the settings file becomes .env next to the program, read-only.
#      History loads it itself (godotenv), so the passwords are not container variables.
#    --log-opt: logs are kept in at most 3 files of 10 MB.
docker rm --force "$CONTAINER" >/dev/null 2>&1 || true
docker run --detach \
  --name "$CONTAINER" \
  --restart unless-stopped \
  --publish 8080:8080 \
  --volume "$ENV_FILE:/app/history/.env:ro" \
  --log-opt max-size=10m --log-opt max-file=3 \
  "$IMAGE" >/dev/null

# 4. After 15 s the container must still be running, must not have been restarted,
#    and the API must answer (it reads PostgreSQL).
sleep 15
state=$(docker inspect --format '{{.State.Running}} {{.RestartCount}}' "$CONTAINER" 2>/dev/null || true)
if [[ "$state" != "true 0" ]] \
  || ! curl --fail --silent --max-time 10 --output /dev/null http://127.0.0.1:8080/api/history; then
  echo "Container $CONTAINER does not work (running, restarts: ${state:-none}). Last log lines:" >&2
  docker logs --tail 20 "$CONTAINER" >&2 || true
  rollback
fi
echo "Container $CONTAINER is running in mode $APP_MODE, /api/history answers"
