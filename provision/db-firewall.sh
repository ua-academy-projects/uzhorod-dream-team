#!/usr/bin/env bash
# Firewall (ufw) of weather-vm: each port is open only to the VMs that need it.
# Services choose the network they listen on; the firewall chooses who may connect.
# Runs last: the rules are rebuilt from this file every time.
set -euo pipefail

for name in FETCHER_IP HISTORY_IP; do
  if [[ ! "${!name:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$name must be an IPv4 address" >&2
    exit 1
  fi
done
if [[ "${APP_MODE:-}" != "rabbitmq" && "${APP_MODE:-}" != "postgres" ]]; then
  echo "APP_MODE must be rabbitmq or postgres" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get install -y ufw

# Start from an empty rule list, so old rules removed from this file disappear too.
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH: vagrant ssh and provisioning. Without this rule Vagrant loses access to the VM.
ufw allow 22/tcp comment 'SSH (Vagrant)'
ufw allow from "$HISTORY_IP" to any port 5432 proto tcp comment 'PostgreSQL: History'
# Fetcher uses PostgreSQL only in app_mode postgres (queue tables, see provision/db-mode.sh).
if [[ "$APP_MODE" == "postgres" ]]; then
  ufw allow from "$FETCHER_IP" to any port 5432 proto tcp comment 'PostgreSQL: Fetcher (mode postgres)'
fi
ufw allow from "$FETCHER_IP" to any port 5672 proto tcp comment 'RabbitMQ: Fetcher'
ufw allow from "$HISTORY_IP" to any port 5672 proto tcp comment 'RabbitMQ: History'
ufw allow from "$HISTORY_IP" to any port 6379 proto tcp comment 'Redis: History'

ufw --force enable
ufw status verbose
