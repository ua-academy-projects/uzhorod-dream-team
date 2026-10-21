#!/usr/bin/env bash
# deploy/set-queue.sh [0|1] — picks the backend from PG_BACKEND in deploy/queue.env and rolls it out to the fetcher and history VMs.
#   0 — RabbitMQ + Redis (the default, also for an empty or any other value), 1 — pgmq + hstore.
# The argument first overwrites PG_BACKEND in the file. The services read QUEUE_URL (+ REDIS_URL), so
# only those two end up in /etc/queue.env on the VMs, not the whole queue.env.
set -euo pipefail
cd "$(dirname "$0")/.."
CONF=deploy/queue.env

if [ $# -gt 0 ]; then
  [[ $1 =~ ^[01]$ ]] || { echo "usage: $0 [0|1]" >&2; exit 2; }
  if grep -q '^PG_BACKEND=' "$CONF"; then sed -i "s/^PG_BACKEND=.*/PG_BACKEND=$1/" "$CONF"; else echo "PG_BACKEND=$1" >>"$CONF"; fi
fi

# read values with sed rather than source: URLs may contain %, & and so on
val()  { sed -n "s/^$1=//p" "$CONF" | tail -n1; }
need() { local v; v=$(val "$1"); [ -n "$v" ] || { echo "$CONF: $1 is not set" >&2; return 1; }; echo "$v"; }

backend=$(val PG_BACKEND)
case "$backend" in 0 | 1 | "") ;; *) echo "warning: PG_BACKEND='$backend' is not 0/1, using 0" >&2 ;; esac
if [ "$backend" = 1 ]; then
  echo "backend: 1 (pgmq + hstore)"
  queue_url=$(need PGMQ_URL)
  redis_url=$(val REDIS_URL)   # in this mode the cache is hstore, Redis is not needed
else
  echo "backend: 0 (RabbitMQ + Redis)"
  queue_url=$(need RABBITMQ_URL)
  redis_url=$(need REDIS_URL)
fi

env_file=$(mktemp)
trap 'rm -f "$env_file"' EXIT
{ echo "QUEUE_URL=$queue_url"; [ -z "$redis_url" ] || echo "REDIS_URL=$redis_url"; } >"$env_file"

ssh_vm() { vagrant ssh "$1" -c "$2"; }
put()    { vagrant upload "$env_file" /tmp/queue.env "$1" &&
           ssh_vm "$1" "sudo install -m600 /tmp/queue.env /etc/queue.env"; }

# 1. stop the fetcher so new messages stop flowing into the old queue
ssh_vm fetcher "sudo systemctl stop fetcher"

# 2. stop history (it will no longer see messages left in the old queue, see README, "Modes: primary / fallback")
ssh_vm history "sudo systemctl stop history"

# 3. update the config on both
put fetcher; put history

# 4. history first, then the fetcher
ssh_vm history "sudo systemctl start history"
ssh_vm fetcher "sudo systemctl start fetcher"
