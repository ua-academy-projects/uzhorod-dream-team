#!/usr/bin/env bash
set -Eeuo pipefail

trap 'rm -f /tmp/kyiv-air-logging-collect-logs.sh' EXIT

apt-get update
apt-get install -y --no-install-recommends openssh-client cron gzip util-linux

install -d -m 0755 /etc/kyiv-air-logging
install -d -m 0700 -o root -g root /var/lib/kyiv-air-log-collector /var/log/kyiv-air-aggregated

printf '%s\n' "$LOG_SOURCES" > /etc/kyiv-air-logging/sources.tsv

if [[ ! -f /var/lib/kyiv-air-log-collector/id_ed25519 ]]; then
  ssh-keygen -q -t ed25519 -N '' -C kyiv-air-log-collector -f /var/lib/kyiv-air-log-collector/id_ed25519
fi

install -m 0755 /tmp/kyiv-air-logging-collect-logs.sh /usr/local/sbin/collect-kyiv-air-logs

rm -f /etc/kyiv-air-logging/logging.enabled

cat > /etc/cron.d/kyiv-air-logs <<'CRON'
*/15 * * * * root /usr/local/sbin/collect-kyiv-air-logs 2>&1 | /usr/bin/logger -t kyiv-air-logs
CRON

chmod 0644 /etc/cron.d/kyiv-air-logs

systemctl enable --now cron
