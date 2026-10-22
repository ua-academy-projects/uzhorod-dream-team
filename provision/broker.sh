#!/usr/bin/env bash
# Provisioning of weather-vm: RabbitMQ, the message queue between History and Fetcher,
# as a Docker container. Docker itself is installed before this script by provision/docker.sh.
# Running it again is safe: the data (users, queues, messages) stay in the volume,
# the container is created again, the password and permissions are set again from .env.
set -euo pipefail

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
if [[ ! "${DB_IP:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "DB_IP must be an IPv4 address" >&2
  exit 1
fi

# The same RabbitMQ (3.12.1) and Erlang (OTP 25) as the Ubuntu 24.04 package that ran here
# before, so the container reads its data directory as it is.
IMAGE=rabbitmq:3.12.1
CONTAINER=weather-rabbitmq
VOLUME=weather-rabbitmq-data
CONFIG_DIR=/etc/weather-rabbitmq
# The node name is part of the data (quorum queues belong to a node), so it is fixed.
# The container uses the network of the VM, so its host name is the VM name: weather-vm.
NODENAME=rabbit@weather-vm
# RabbitMQ before Docker (Ubuntu package + systemd). The package and its data are kept for a rollback.
OLD_SERVICE=rabbitmq-server.service
OLD_DATA=/var/lib/rabbitmq
BACKUP_DIR=/var/backups/weather-rabbitmq

# The container runs as the user rabbitmq of this VM (created by the old package), not as root
# and not as uid 999 of the image: in this VM gid 999 is the system group systemd-journal.
if ! id rabbitmq >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin rabbitmq
fi
RABBITMQ_UID=$(id -u rabbitmq)
RABBITMQ_GID=$(id -g rabbitmq)

old_service_exists() {
  [[ -n "$(systemctl list-unit-files "$OLD_SERVICE" --no-legend)" ]]
}

# rabbitmqctl inside the container (as the user of the container).
ctl() {
  docker exec "$CONTAINER" rabbitmqctl --quiet "$@"
}

# docker stop with time: RabbitMQ shuts down cleanly and writes its queues to disk.
remove_container() {
  docker stop --time 60 "$CONTAINER" >/dev/null 2>&1 || true
  docker rm "$CONTAINER" >/dev/null 2>&1 || true
}

# Gives the work back to the old RabbitMQ, if it is still in this VM.
rollback() {
  remove_container
  if old_service_exists; then
    systemctl enable --now "$OLD_SERVICE"
    echo "Rollback: the old $OLD_SERVICE is running again" >&2
  fi
  exit 1
}

# 1. Download the image. If it fails, set -e stops the script here, the old RabbitMQ keeps working.
docker pull "$IMAGE"

# 2. Config outside the image; the container gets the whole folder read-only instead of the
#    image defaults (they allow guest from the network and turn on the Prometheus plugin).
#    No secrets here: the password is set below with rabbitmqctl and kept as a hash in the data.
install -d -m 0755 "$CONFIG_DIR" "$CONFIG_DIR/conf.d"
cat > "$CONFIG_DIR/rabbitmq.conf" <<EOF
# AMQP only on the private network between the VMs.
# Who may connect is chosen by db-firewall.sh.
listeners.tcp.1 = $DB_IP:5672

# Logs to the container output (docker logs), not to files.
log.console = true
log.file = false
EOF
# No plugins, as before: no management UI, no metrics port.
echo '[].' > "$CONFIG_DIR/enabled_plugins"
chmod 0644 "$CONFIG_DIR/rabbitmq.conf" "$CONFIG_DIR/enabled_plugins"

# 3. Volume for the data: it is kept when the container is removed and created again.
docker volume create "$VOLUME" >/dev/null
volume_dir=$(docker volume inspect --format '{{.Mountpoint}}' "$VOLUME")
chown rabbitmq:rabbitmq "$volume_dir"
chmod 0750 "$volume_dir"

# 4. Old RabbitMQ still running: export users, vhosts, permissions and queues as a backup
#    (with password hashes, so only root can read it) and note the messages in the queues.
#    Messages are not in this export: they stay in the data folder that is copied below.
if old_service_exists && systemctl is-active --quiet "$OLD_SERVICE"; then
  install -d -m 0700 "$BACKUP_DIR"
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  # "-": to standard output. rabbitmqctl runs as the user rabbitmq, which cannot write
  # into BACKUP_DIR, so root writes the file.
  (umask 077; rabbitmqctl --quiet export_definitions - > "$BACKUP_DIR/definitions-$stamp.json")
  echo "Messages before the move:"
  rabbitmqctl --quiet list_queues -p "$RABBITMQ_VHOST" name messages
fi

# 5. Only one RabbitMQ on port 5672: the old service is stopped right before the container
#    starts. It shuts down cleanly, so its data folder (with the messages) is complete.
if old_service_exists && systemctl is-active --quiet "$OLD_SERVICE"; then
  systemctl disable --now "$OLD_SERVICE"
  tar -C "$OLD_DATA" -czf "$BACKUP_DIR/var-lib-rabbitmq-$stamp.tar.gz" .
  chmod 0600 "$BACKUP_DIR/var-lib-rabbitmq-$stamp.tar.gz"
elif old_service_exists; then
  systemctl disable "$OLD_SERVICE" >/dev/null 2>&1 || true
fi

# 6. The data of the old RabbitMQ (node, users, queues, messages, Erlang cookie) go into the
#    volume, but only if the volume has no data yet: a new provisioning must never overwrite
#    newer data with old ones.
if [[ ! -e "$volume_dir/mnesia" && -d "$OLD_DATA/mnesia" ]]; then
  cp -a "$OLD_DATA/." "$volume_dir/"
  echo "Data of the old RabbitMQ copied into the volume $VOLUME"
fi

# 7. The container from the previous provisioning is stopped cleanly and created again.
#    --network host: RabbitMQ listens on DB_IP:5672 of the VM itself, as before. No published
#      ports, so the ufw rules of db-firewall.sh apply (a port published with --publish
#      would bypass ufw).
#    --env RABBITMQ_NODENAME: the same node name as before, also after a VM reboot.
#    --user: the user rabbitmq of this VM, not root.
#    --restart unless-stopped: Docker starts it again after a crash and after a VM reboot.
remove_container
docker run --detach \
  --name "$CONTAINER" \
  --restart unless-stopped \
  --network host \
  --env RABBITMQ_NODENAME="$NODENAME" \
  --user "$RABBITMQ_UID:$RABBITMQ_GID" \
  --volume "$CONFIG_DIR:/etc/rabbitmq:ro" \
  --volume "$VOLUME:/var/lib/rabbitmq" \
  --log-opt max-size=10m --log-opt max-file=3 \
  "$IMAGE" >/dev/null

# 8. Wait until RabbitMQ is ready (up to 2 minutes), otherwise roll back.
ready=no
for _ in $(seq 1 60); do
  if docker exec "$CONTAINER" rabbitmq-diagnostics --quiet check_running >/dev/null 2>&1 \
    && docker exec "$CONTAINER" rabbitmq-diagnostics --quiet check_port_listener 5672 >/dev/null 2>&1; then
    ready=yes
    break
  fi
  sleep 2
done
restarts=$(docker inspect --format '{{.RestartCount}}' "$CONTAINER" 2>/dev/null || echo none)
if [[ "$ready" != yes || "$restarts" != 0 ]]; then
  echo "Container $CONTAINER is not ready (restarts: $restarts). Last log lines:" >&2
  docker logs --tail 30 "$CONTAINER" >&2 || true
  rollback
fi

# 9. vhost, user and permissions, the same way as before Docker. On a new VM they are created,
#    otherwise the password and permissions are set again from .env.
if ! ctl list_vhosts name | grep -qx "$RABBITMQ_VHOST"; then
  ctl add_vhost "$RABBITMQ_VHOST"
fi
# The password goes through standard input (not in the command arguments),
# so it is not visible in the process list.
if ctl list_users | awk '{ print $1 }' | grep -qx "$RABBITMQ_USER"; then
  printf '%s' "$RABBITMQ_PASSWORD" | docker exec -i "$CONTAINER" rabbitmqctl --quiet change_password "$RABBITMQ_USER"
else
  printf '%s' "$RABBITMQ_PASSWORD" | docker exec -i "$CONTAINER" rabbitmqctl --quiet add_user "$RABBITMQ_USER"
fi
# Three permissions in the vhost: configure (create queues), write (publish), read (consume).
ctl set_permissions -p "$RABBITMQ_VHOST" "$RABBITMQ_USER" '.*' '.*' '.*'
# The default user guest/guest has a well-known password, so it is removed.
if ctl list_users | awk '{ print $1 }' | grep -qx guest; then
  ctl delete_user guest
fi

echo "Container $CONTAINER is running. Queues (name, messages, consumers):"
ctl list_queues -p "$RABBITMQ_VHOST" name messages consumers
