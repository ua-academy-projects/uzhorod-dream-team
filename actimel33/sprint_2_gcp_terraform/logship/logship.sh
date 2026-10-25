#!/usr/bin/env bash
# Run by cron every 15 min: new container log lines -> collector on db over ssh.
# A batch is deleted only after the collector took it; until then it waits in
# the spool. On any doubt the window is read again: duplicates beat gaps.
set -euo pipefail

# shellcheck disable=SC1091
. /etc/logship/logship.conf # LOGSHIP_COLLECTOR
SPOOL=/var/spool/logship
KEY=/etc/logship/id_ed25519
NAME_RE='^[a-z0-9_-]{1,64}$'

# Read every container from the previous run up to now into spool files.
collect() {
  local since until names c out failed=0
  since=$(cat "$SPOOL/.since" 2>/dev/null || true)
  until=$(date +%s.%N)
  # A separate assignment: with set -e a failing docker stops the run here,
  # before .since moves. Inside `for ... in $(...)` the failure would be ignored.
  names=$(docker ps -a --format '{{.Names}}')
  for c in $names; do
    if [[ ! $c =~ $NAME_RE ]]; then
      echo "skip $c: name not accepted by the collector" >&2
      continue
    fi
    out="$SPOOL/$c.$until.log"
    if ! docker logs --timestamps ${since:+--since "$since"} --until "$until" "$c" > "$out" 2>&1; then
      rm -f "$out"
      failed=1
    fi
    [ -s "$out" ] || rm -f "$out"
  done
  if [ "$failed" = 0 ]; then
    echo "$until" > "$SPOOL/.since"
  fi
}

# Oldest batch of each container first; stop at the first failure.
send() {
  local f c
  for f in "$SPOOL"/*.log; do
    [ -e "$f" ] || return 0
    c=$(basename "$f")
    c=${c%%.*}
    if ssh -i "$KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 \
         -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
         "$LOGSHIP_COLLECTOR" "$c" < "$f"; then
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
