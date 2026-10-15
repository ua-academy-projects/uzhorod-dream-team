#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ENV_DIR=/etc/weather

base_setup() {
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl

  install -d -m 0700 -o vagrant -g vagrant /home/vagrant/.ssh
  grep -qxF "${SSH_PUBKEY:?}" /home/vagrant/.ssh/authorized_keys 2>/dev/null \
    || echo "$SSH_PUBKEY" >> /home/vagrant/.ssh/authorized_keys
}

install_docker() {
  if ! command -v docker >/dev/null; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  fi
  local conf
  conf=$(mktemp)
  cat > "$conf" <<'JSON'
{
  "log-driver": "journald",
  "log-opts": { "tag": "{{.Name}}" },
  "live-restore": true
}
JSON
  if ! cmp -s "$conf" /etc/docker/daemon.json; then
    docker ps -aq | xargs -r docker rm -f >/dev/null
    install -m 0644 "$conf" /etc/docker/daemon.json
    systemctl restart docker
  fi
  rm -f "$conf"
  systemctl enable --now docker
  usermod -aG docker vagrant
  install -d -m 0750 -o root -g docker "$ENV_DIR"
}

write_env() {
  install -m 0640 -o root -g docker /dev/stdin "$ENV_DIR/$1.env"
}

write_conf() {
  local path=$ENV_DIR/$1 mode=$2 owner=${3:-root}
  install -d -m 0750 -o root -g docker "$(dirname "$path")"
  install -m "$mode" -o "$owner" -g docker /dev/stdin "$path"
}

build_image() {
  local attempt
  for attempt in 1 2 3; do
    docker build -t "weather/$1" "/vagrant/$1" && break
    [ "$attempt" -lt 3 ] || return 1
    echo "build of weather/$1 failed (attempt $attempt/3), retrying in 10s" >&2
    sleep 10
  done
  docker image prune -f >/dev/null
}

ensure_network() {
  docker network inspect "$1" >/dev/null 2>&1 || docker network create "$1" >/dev/null
}

LOG_EXPORT_DIR=/var/log/weather-export
LOG_REMOTE_DIR=/var/log/weather-remote
LOG_STATE_DIR=/var/lib/weather-logs

setup_journald() {
  local conf
  conf=$(mktemp)
  cat > "$conf" <<CONF
[Journal]
Storage=persistent
MaxRetentionSec=${LOG_RETENTION_DAYS:?}day
SystemMaxUse=200M
CONF
  install -d -m 0755 /etc/systemd/journald.conf.d
  if ! cmp -s "$conf" /etc/systemd/journald.conf.d/50-weather.conf; then
    install -m 0644 "$conf" /etc/systemd/journald.conf.d/50-weather.conf
    systemctl restart systemd-journald
  fi
  rm -f "$conf"
}

install_timer() {
  local name=$1 calendar=$2
  cat > "/etc/systemd/system/$name.service" <<UNIT
[Unit]
Description=$name

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/$name
UNIT
  cat > "/etc/systemd/system/$name.timer" <<UNIT
[Unit]
Description=Run $name on $calendar

[Timer]
OnCalendar=$calendar
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now "$name.timer"
}

setup_log_export() {
  apt-get install -y -qq zstd rsync >/dev/null

  install -m 0755 /dev/stdin /usr/local/sbin/weather-log-serve <<SH
#!/usr/bin/env bash
if [[ "\${SSH_ORIGINAL_COMMAND:-}" =~ ^rsync\ --server\ --sender\ (-[a-zA-Z.]+)\ \.\ \.?$ ]]; then
  exec rsync --server --sender "\${BASH_REMATCH[1]}" . $LOG_EXPORT_DIR/
fi
echo "only rsync downloads from $LOG_EXPORT_DIR are allowed" >&2
exit 1
SH
  id logpull >/dev/null 2>&1 || useradd --system --create-home --shell /bin/sh logpull
  install -d -m 0700 -o logpull -g logpull /home/logpull/.ssh
  install -m 0600 -o logpull -g logpull /dev/stdin /home/logpull/.ssh/authorized_keys <<KEYS
restrict,from="${HISTORY_IP:?}",command="/usr/local/sbin/weather-log-serve" ${LOGPULL_PUBKEY:?}
KEYS
  install -d -m 0750 -o root -g logpull "$LOG_EXPORT_DIR"
  install -d -m 0700 "$LOG_STATE_DIR"
  echo "e $LOG_EXPORT_DIR - - - ${LOG_RETENTION_DAYS:?}d" > /etc/tmpfiles.d/weather-log-export.conf

  install -m 0755 /dev/stdin /usr/local/sbin/weather-log-export <<SH
#!/usr/bin/env bash
set -euo pipefail
raw=\$(mktemp -p $LOG_STATE_DIR export.XXXXXX)
trap 'rm -f "\$raw" "\$raw.zst"' EXIT
journalctl --cursor-file=$LOG_STATE_DIR/cursor -o export --no-pager > "\$raw"
[ -s "\$raw" ] || exit 0
zstd -q -T0 "\$raw" -o "\$raw.zst"
chgrp logpull "\$raw.zst"
chmod 0640 "\$raw.zst"
mv "\$raw.zst" "$LOG_EXPORT_DIR/\$(hostname)-\$(date -u +%Y%m%dT%H%M%SZ).export.zst"
SH
  install_timer weather-log-export "*:0/15"
}

setup_log_pull() {
  apt-get install -y -qq zstd rsync systemd-journal-remote >/dev/null
  systemctl disable --now systemd-journal-remote.socket systemd-journal-remote.service >/dev/null 2>&1 || true

  base64 -d <<<"${LOGPULL_KEY_B64:?}" | install -m 0600 /dev/stdin "$ENV_DIR/logpull_ed25519"
  install -m 0644 /dev/stdin "$ENV_DIR/log-sources" <<<"${LOG_SOURCES:?}"
  install -d -m 0700 "$LOG_STATE_DIR"
  rm -f "$LOG_STATE_DIR/known_hosts"
  install -d -m 0750 "$LOG_REMOTE_DIR"
  install -d -m 2755 /var/log/journal/remote
  echo "e $LOG_REMOTE_DIR - - - ${LOG_RETENTION_DAYS:?}d" > /etc/tmpfiles.d/weather-log-pull.conf
  echo "e /var/log/journal/remote - - - ${LOG_RETENTION_DAYS:?}d" >> /etc/tmpfiles.d/weather-log-pull.conf

  install -m 0755 /dev/stdin /usr/local/sbin/weather-log-pull <<SH
#!/usr/bin/env bash
set -uo pipefail
ssh="ssh -i $ENV_DIR/logpull_ed25519 -o BatchMode=yes -o ConnectTimeout=10 \\
  -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$LOG_STATE_DIR/known_hosts"
imported=$LOG_STATE_DIR/imported
touch "\$imported"
status=0
for src in \$(cat $ENV_DIR/log-sources); do
  name=\${src%%=*} ip=\${src#*=}
  install -d -m 0750 "$LOG_REMOTE_DIR/\$name"
  if ! rsync -rt --chmod=F0640 --ignore-existing --include='*.export.zst' --exclude='*' \\
      -e "\$ssh" "logpull@\$ip:" "$LOG_REMOTE_DIR/\$name/"; then
    echo "pull from \$name (\$ip) failed" >&2
    status=1
    continue
  fi
  for f in "$LOG_REMOTE_DIR/\$name"/*.export.zst; do
    [ -e "\$f" ] || continue
    entry=\$name/\${f##*/}
    grep -qxF "\$entry" "\$imported" && continue
    if zstdcat "\$f" | sed "s/^_HOSTNAME=.*/_HOSTNAME=\$name/" \\
        | /lib/systemd/systemd-journal-remote --split-mode=none \\
        -o "/var/log/journal/remote/\$name-\$(date -u +%Y%m%d).journal" -; then
      echo "\$entry" >> "\$imported"
    else
      echo "import of \$entry failed" >&2
      status=1
    fi
  done
done
while read -r entry; do
  [ -e "$LOG_REMOTE_DIR/\$entry" ] && echo "\$entry"
done < "\$imported" > "\$imported.new"
mv "\$imported.new" "\$imported"
exit \$status
SH
  install_timer weather-log-pull "*:5/15"
}

wait_healthy() {
  local attempt
  for attempt in $(seq 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$1")" = healthy ] && return 0
    sleep 2
  done
  echo "container $1 is not healthy after 2 minutes" >&2
  return 1
}

# The first start of an empty volume restarts PostgreSQL once after init, so retry a few times
psql_as_postgres() {
  local sql attempt
  sql=$(cat)
  for attempt in 1 2 3 4 5; do
    docker exec -i -e PGOPTIONS='-c client_min_messages=warning' postgres \
      psql -X -q -v ON_ERROR_STOP=1 -U postgres -d "$1" <<<"$sql" && return 0
    [ "$attempt" -lt 5 ] && sleep 3
  done
  return 1
}

save_run() {
  local name=$1
  shift
  printf '%q ' "$@" | install -m 0640 -o root -g docker /dev/stdin "$ENV_DIR/$name.run"
}

# start_saved <container> <run file>: (re)creates the container from $ENV_DIR/<run file>.run
start_saved() {
  docker rm -f "$1" >/dev/null 2>&1 || true
  eval "docker run -d --name $1 --restart unless-stopped --env-file $ENV_DIR/$1.env $(cat "$ENV_DIR/$2.run")" >/dev/null
  echo "started container $1 ($(docker inspect -f '{{.Config.Image}}' "$1"))"
}

run_container() {
  save_run "$@"
  start_saved "$1" "$1"
}

install_backend_switch() {
  install -m 0755 /dev/stdin /usr/local/bin/weather-backend <<SH
#!/usr/bin/env bash
set -euo pipefail
containers=($*)
SH
  cat >> /usr/local/bin/weather-backend <<'SH'
env_dir=/etc/weather

show() {
  for name in "${containers[@]}"; do
    printf '%s: USE_REDIS_RABBITMQ=%s\n' "$name" \
      "$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" | sed -n 's/^USE_REDIS_RABBITMQ=//p')"
  done
}

arg=${1:-}
case "${arg,,}" in
  "") show; exit 0 ;;
  true | 1 | yes) value=true ;;
  false | 0 | no) value=false ;;
  *) echo "usage: weather-backend [true|false]   (true: Redis + RabbitMQ, false: PostgreSQL)" >&2; exit 2 ;;
esac
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"

for name in "${containers[@]}"; do
  image=$(docker inspect -f '{{.Image}}' "$name")
  sed -i "s/^USE_REDIS_RABBITMQ=.*/USE_REDIS_RABBITMQ=$value/" "$env_dir/$name.env"
  docker rm -f "$name" >/dev/null
  eval "docker run -d --name $name --restart unless-stopped --env-file $env_dir/$name.env $(cat "$env_dir/$name.run")" >/dev/null
  if [ "$(docker inspect -f '{{.Image}}' "$name")" = "$image" ]; then
    echo "$name: recreated from the same image ${image:7:12}"
  else
    echo "$name: warning: the image tag changed since the last start, started from the newer image" >&2
  fi
done
show
SH
}
