#!/usr/bin/env bash
# Log collector on db: user logs accepts batches only through logsink.
set -euo pipefail

# A real shell is required: sshd runs the forced command through it.
# The account has no password, so the only way in is a restricted key.
id logs >/dev/null 2>&1 ||
  useradd --system --home-dir /srv/logs --shell /bin/sh logs
install -d -o logs -g logs -m 0750 /srv/logs

install -m 0755 /home/vagrant/app/logship/logsink.sh /usr/local/bin/logsink

# root-owned: logs cannot rewrite its own keys.
install -d -o root -g logs -m 0750 /srv/logs/.ssh
install -o root -g logs -m 0640 /tmp/logship_authorized_keys /srv/logs/.ssh/authorized_keys
rm -f /tmp/logship_authorized_keys

cat > /etc/logrotate.d/logship <<'CONF'
/srv/logs/*/*.log {
  su logs logs
  daily
  rotate 7
  compress
  delaycompress
  missingok
  notifempty
}
CONF