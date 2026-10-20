#!/bin/bash
set -euo pipefail

LOG_DIR="/var/log/remote"
SOURCE_SCRIPT="/vagrant/scripts/ssh/collect_logs.sh"
COLLECT_SCRIPT="/usr/local/bin/collect_logs.sh"

sudo mkdir -p "$LOG_DIR"
sudo chown vagrant:vagrant "$LOG_DIR"
sudo chmod 755 "$LOG_DIR"

sudo install -o vagrant -g vagrant -m 755 \
    "$SOURCE_SCRIPT" "$COLLECT_SCRIPT"

CRON_JOB="*/15 * * * * $COLLECT_SCRIPT"

(
    sudo crontab -u vagrant -l 2>/dev/null || true
    echo "$CRON_JOB"
) | sort -u | sudo crontab -u vagrant -