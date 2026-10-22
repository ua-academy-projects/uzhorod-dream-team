#!/usr/bin/env bash
# Time synchronization for every VM via systemd-timesyncd (NTP).
# Fetcher writes fetched_at from the VM clock, so the clock must be correct,
# also after Windows sleeps and the VM is paused.
set -euo pipefail

# The VirtualBox Guest Additions service (vboxadd-service) is declared as conflicting
# with systemd-timesyncd: while vboxadd-service runs, timesyncd is stopped. It corrects
# the clock only if it is more than 20 minutes off, and we do not use its other
# features (shared folders are disabled), so it is turned off.
# The Guest Additions kernel modules (vboxadd) are not affected.
if [[ -n "$(systemctl list-unit-files vboxadd-service.service --no-legend)" ]]; then
  systemctl disable --now vboxadd-service.service
fi

install -d /etc/systemd/timesyncd.conf.d
cat > /etc/systemd/timesyncd.conf.d/weather-history.conf <<'EOF'
[Time]
NTP=ntp.ubuntu.com
FallbackNTP=pool.ntp.org
# Check the clock at least every 128 s (default: up to 34 min). After Windows sleeps,
# the VM is restored with its clock stopped at the moment it was saved; without this
# it stays minutes behind until the next check.
PollIntervalMaxSec=128
EOF

# set-ntp true enables and starts systemd-timesyncd; restart applies the config above.
timedatectl set-ntp true
systemctl restart systemd-timesyncd.service

# Wait up to 60 seconds for the first successful synchronization.
for _ in $(seq 1 30); do
  if [[ "$(timedatectl show -p NTPSynchronized --value)" == "yes" ]]; then
    echo "Time synchronized via NTP"
    exit 0
  fi
  sleep 2
done
echo "WARNING: time is not synchronized yet; check internet access (UDP port 123)" >&2
