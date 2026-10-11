#!/usr/bin/env bash
# Run by cron every 15 min.
# A batch is deleted only after the collector took it.
# Lines wait in the spool.
set -euo pipefail

CONF="${LOGSHIP_CONF:-/etc/logship/logship.conf}"
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

SPOOL="${LOGSHIP_SPOOL:-/var/spool/logship}"
KEY="${LOGSHIP_KEY:-/etc/logship/id_ed25519}"
COLLECTOR="${LOGSHIP_COLLECTOR:?LOGSHIP_COLLECTOR is not set}"
NAME_RE='^[a-z0-9_-]{1,64}$'

# Read every container from the previous run up to now into spool files.
collect() {
  local since until c out
  since=$(cat "$SPOOL/.since" 2>/dev/null || true)
  until=$(date +%s.%N)
  for c in $(docker ps -a --format '{{.Names}}'); do
    if [[ ! $c =~ $NAME_RE ]]; then
      echo "skip $c: name not accepted by the collector" >&2
      continue
    fi
    out="$SPOOL/$c.$until.log"
    if ! docker logs --timestamps ${since:+--since "$since"} --until "$until" "$c" > "$out" 2>&1; then
      rm -f "$out" # removed while reading
    fi
    [ -s "$out" ] || rm -f "$out"
  done
  echo "$until" > "$SPOOL/.since"
}

# Oldest first; stop at the first failure to keep the order.
send() {
  local f c
  for f in "$SPOOL"/*.log; do
    [ -e "$f" ] || return 0
    c=$(basename "$f")
    c=${c%%.*}
    if ssh -i "$KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 \
         -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
         "$COLLECTOR" "$c" < "$f"; then
      rm -f "$f"
    else
      echo "collector unreachable, $(find "$SPOOL" -name '*.log' | wc -l) batch(es) kept" >&2
      return 0
    fi
  done
}

mkdir -p "$SPOOL"
exec 9> "$SPOOL/.lock"
flock -n 9 || exit 0 # previous run still going

collect
send