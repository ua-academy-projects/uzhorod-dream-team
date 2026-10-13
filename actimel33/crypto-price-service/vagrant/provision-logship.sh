#!/usr/bin/env bash
# Log shipper: cron sends this machine's container logs to the collector on db.
set -euo pipefail

: "${LOGSHIP_COLLECTOR:?LOGSHIP_COLLECTOR must be provided by the provisioner}"

install -d -m 0700 /etc/logship /var/spool/logship
install -m 0600 /tmp/logship_key /etc/logship/id_ed25519
rm -f /tmp/logship_key
install -m 0755 /home/vagrant/app/logship/logship.sh /usr/local/bin/logship
echo "LOGSHIP_COLLECTOR=$LOGSHIP_COLLECTOR" > /etc/logship/logship.conf

cat > /etc/cron.d/logship <<'CRON'
# Container logs -> collector on db; errors in: journalctl -t logship
*/15 * * * * root /usr/local/bin/logship 2>&1 | logger -t logship
CRON
