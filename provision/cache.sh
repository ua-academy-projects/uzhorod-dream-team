#!/usr/bin/env bash
# Provisioning of weather-vm: Redis, the cache for the user settings of the UI,
# as a Docker container. Docker itself is installed before this script by provision/docker.sh.
# Running it again is safe: the data stay in the volume, the container is created again.
set -euo pipefail

if [[ ! "${REDIS_PASSWORD:-}" =~ ^[A-Za-z0-9]{16,}$ ]]; then
  echo "REDIS_PASSWORD must be at least 16 letters or digits" >&2
  exit 1
fi
if [[ ! "${DB_IP:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "DB_IP must be an IPv4 address" >&2
  exit 1
fi

# The same version as the Ubuntu 24.04 package that ran Redis here before (same data format).
IMAGE=redis:7.0.15
CONTAINER=weather-redis
VOLUME=weather-redis-data
CONFIG_DIR=/etc/weather-redis
CONFIG=$CONFIG_DIR/redis.conf
# Redis before Docker (Ubuntu package + systemd). The package and its data are kept for a rollback.
OLD_SERVICE=redis-server.service
OLD_DATA=/var/lib/redis/dump.rdb
BACKUP_DIR=/var/backups/weather-redis
# redis-cli reads the password from this variable, so it is not in the command arguments.
export REDISCLI_AUTH=$REDIS_PASSWORD

# The container runs as the user redis of this VM (created by the old package), not as root.
# The config with the password stays readable only for root and the group redis.
# Not uid 999 of the image: in this VM gid 999 is the system group systemd-journal.
if ! id redis >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin redis
fi
REDIS_UID=$(id -u redis)
REDIS_GID=$(id -g redis)

old_service_exists() {
  [[ -n "$(systemctl list-unit-files "$OLD_SERVICE" --no-legend)" ]]
}

# docker stop (not rm --force): Redis gets SIGTERM and saves dump.rdb before it exits.
remove_container() {
  docker stop --time 30 "$CONTAINER" >/dev/null 2>&1 || true
  docker rm "$CONTAINER" >/dev/null 2>&1 || true
}

# Gives the work back to the old Redis, if it is still in this VM.
rollback() {
  remove_container
  if old_service_exists; then
    systemctl enable --now "$OLD_SERVICE"
    echo "Rollback: the old $OLD_SERVICE is running again" >&2
  fi
  exit 1
}

# 1. Download the image. If it fails, set -e stops the script here, the old Redis keeps working.
docker pull "$IMAGE"

# 2. Config outside the image; the container gets it read-only.
install -d -m 0750 -o root -g redis "$CONFIG_DIR"
(
  umask 027
  cat > "$CONFIG" <<EOF
# Localhost and the private network between the VMs (the container uses the network of the VM).
# Who may connect is chosen by db-firewall.sh.
bind 127.0.0.1 $DB_IP
port 6379
protected-mode yes
requirepass $REDIS_PASSWORD

# The cache must not take the memory of PostgreSQL and RabbitMQ.
# When 64 MB are full, Redis removes keys with a TTL that were used long ago.
maxmemory 64mb
maxmemory-policy volatile-lru

# Save to disk (RDB) if at least 1 key changed in 60 seconds,
# so the settings survive a restart of the container or the VM. /data is the volume.
save 60 1
dir /data
dbfilename dump.rdb
appendonly no
EOF
)
chown root:redis "$CONFIG"
chmod 0640 "$CONFIG"

# 3. Volume for the data: it is kept when the container is removed and created again.
docker volume create "$VOLUME" >/dev/null
volume_dir=$(docker volume inspect --format '{{.Mountpoint}}' "$VOLUME")
chown redis:redis "$volume_dir"
chmod 0750 "$volume_dir"

# 4. Old Redis still running: save its data now and keep a dated copy.
if old_service_exists && systemctl is-active --quiet "$OLD_SERVICE"; then
  redis-cli -h 127.0.0.1 SAVE >/dev/null
  install -d -m 0700 "$BACKUP_DIR"
  cp -p "$OLD_DATA" "$BACKUP_DIR/dump-$(date -u +%Y%m%dT%H%M%SZ).rdb"
fi

# 5. Only one Redis on port 6379: the old service is stopped right before the container starts.
#    On stop it saves dump.rdb once more.
if old_service_exists; then
  systemctl disable --now "$OLD_SERVICE"
fi

# 6. The data of the old Redis go into the volume, but only if the volume has no data yet:
#    a new provisioning must never overwrite newer data with old ones.
if [[ ! -e "$volume_dir/dump.rdb" && -e "$OLD_DATA" ]]; then
  cp -p "$OLD_DATA" "$volume_dir/dump.rdb"
  chown redis:redis "$volume_dir/dump.rdb"
  echo "Data of the old Redis copied into the volume $VOLUME"
fi

# 7. The container from the previous provisioning is stopped (data saved) and created again.
#    --network host: Redis listens on the addresses of the VM itself (127.0.0.1 and DB_IP), as
#      before. No published port, so the ufw rules of db-firewall.sh apply to Redis as before
#      (a port published with --publish would bypass ufw).
#    --user: the user redis of this VM, not root.
#    --restart unless-stopped: Docker starts it again after a crash and after a VM reboot.
remove_container
docker run --detach \
  --name "$CONTAINER" \
  --restart unless-stopped \
  --network host \
  --user "$REDIS_UID:$REDIS_GID" \
  --volume "$CONFIG:/usr/local/etc/redis/redis.conf:ro" \
  --volume "$VOLUME:/data" \
  --log-opt max-size=10m --log-opt max-file=3 \
  "$IMAGE" redis-server /usr/local/etc/redis/redis.conf >/dev/null

# 8. After 15 s the container must still be running, must not have been restarted,
#    and Redis must answer with the password.
sleep 15
state=$(docker inspect --format '{{.State.Running}} {{.RestartCount}}' "$CONTAINER" 2>/dev/null || true)
if [[ "$state" != "true 0" ]] \
  || [[ "$(docker exec --env REDISCLI_AUTH "$CONTAINER" redis-cli PING 2>/dev/null)" != "PONG" ]]; then
  echo "Container $CONTAINER does not work (running, restarts: ${state:-none}). Last log lines:" >&2
  docker logs --tail 20 "$CONTAINER" >&2 || true
  rollback
fi
echo "Container $CONTAINER is running, keys: $(docker exec --env REDISCLI_AUTH "$CONTAINER" redis-cli DBSIZE)"
