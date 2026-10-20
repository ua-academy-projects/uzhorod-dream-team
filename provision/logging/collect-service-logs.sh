#!/usr/bin/env bash
set -uo pipefail

LOG_DIR="/var/log/services"
SSH_KEY="/root/.ssh/history_log_collector"
KNOWN_HOSTS="/root/.ssh/known_hosts"
SINCE="15m"

source /etc/service-logs.conf

SSH_OPTS=(
  -i "$SSH_KEY"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o ConnectTimeout=10
)

exec 9>/run/lock/collect-service-logs.lock
flock -n 9 || exit 0

mkdir -p "$LOG_DIR"

collect_remote() {
  local host="$1"
  local container="$2"
  local logfile="$3"
  local rc

  {
    echo "===== host=$host container=$container started=$(date -Is) ====="

    if ssh "${SSH_OPTS[@]}" "vagrant@$host" \
      "sudo -n docker logs --timestamps --since '$SINCE' '$container'" 2>&1
    then
      rc=0
    else
      rc=$?
    fi

    echo "===== exit_code=$rc finished=$(date -Is) ====="
  } >> "$LOG_DIR/$logfile"
}

collect_local() {
  local container="$1"
  local logfile="$2"

  {
    echo "===== container=$container started=$(date -Is) ====="

    if docker logs --timestamps --since "$SINCE" "$container" 2>&1; then
      echo "===== exit_code=0 finished=$(date -Is) ====="
    else
      echo "===== exit_code=$? finished=$(date -Is) ====="
    fi
  } >> "$LOG_DIR/$logfile"
}

collect_remote "$FETCHER_IP" "$FETCHER_CONTAINER" fetcher.log

collect_remote "$POSTGRES_IP" "$POSTGRES_CONTAINER" postgres.log
collect_remote "$POSTGRES_IP" "$REDIS_CONTAINER" redis.log
collect_remote "$POSTGRES_IP" "$RABBITMQ_CONTAINER" rabbitmq.log

collect_remote "$UI_IP" "$UI_CONTAINER" ui.log

collect_local "$HISTORY_CONTAINER" history.log