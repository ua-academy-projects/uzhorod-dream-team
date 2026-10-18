#!/bin/bash
set -euo pipefail

USER_NAME=logcollector
HOME_DIR=/home/$USER_NAME
UPLOAD=/home/vagrant/log_collector_ed25519
CONF_DIR=/etc/iss-log-collector

trap 'rm -f "$UPLOAD"' EXIT

id "$USER_NAME" >/dev/null 2>&1 \
  || useradd --system --create-home --home-dir "$HOME_DIR" --shell /usr/sbin/nologin "$USER_NAME"

install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$HOME_DIR/.ssh"
install -m 600 -o "$USER_NAME" -g "$USER_NAME" "$UPLOAD" "$HOME_DIR/.ssh/id_ed25519"

for src in $LOG_SOURCES; do
  printf 'Host %s\n  HostName %s\n  User logreader\n  IdentityFile ~/.ssh/id_ed25519\n  IdentitiesOnly yes\n  StrictHostKeyChecking yes\n  LogLevel ERROR\n\n' \
    "${src%%=*}" "${src#*=}"
done > "$HOME_DIR/.ssh/config"
chown "$USER_NAME:$USER_NAME" "$HOME_DIR/.ssh/config"
chmod 600 "$HOME_DIR/.ssh/config"

install -d -m 755 "$CONF_DIR"
for src in $LOG_SOURCES; do echo "${src%%=*}"; done > "$CONF_DIR/sources"
echo "RETENTION_DAYS=$LOG_RETENTION_DAYS" > "$CONF_DIR/config"

install -d -m 750 -o "$USER_NAME" -g "$USER_NAME" /var/log/iss /var/lib/iss-log-collector

cat > /usr/local/bin/iss-collect-logs <<'EOF'
#!/bin/bash
set -euo pipefail
source /etc/iss-log-collector/config
cd /

LOGS=/var/log/iss
STATE=/var/lib/iss-log-collector
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
day=$(date -u +%F)

mkdir -p "$LOGS/collector"
log() { echo "$now $*" >> "$LOGS/collector/$day.log"; }

while read -r name; do
  [[ -n $name ]] || continue
  since=$(cat "$STATE/$name.since" 2>/dev/null || date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$LOGS/$name"
  out=$(mktemp)
  err=$(mktemp)
  if ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$name" "$since $now" >"$out" 2>"$err"; then
    cat "$out" >> "$LOGS/$name/$day.log"
    echo "$now" > "$STATE/$name.since"
    log "$name ok lines=$(wc -l <"$out") since=$since"
  else
    log "$name FAILED: $(tr '\n' ' ' <"$err")"
  fi
  rm -f "$out" "$err"
done < /etc/iss-log-collector/sources

find "$LOGS" -type f -name '*.log' -mtime +"$RETENTION_DAYS" -delete
EOF
chown root:root /usr/local/bin/iss-collect-logs
chmod 755 /usr/local/bin/iss-collect-logs

cat > /etc/cron.d/iss-log-collector <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$LOG_COLLECT_CRON $USER_NAME flock -n /run/lock/iss-log-collector.lock /usr/local/bin/iss-collect-logs
EOF
chmod 644 /etc/cron.d/iss-log-collector
