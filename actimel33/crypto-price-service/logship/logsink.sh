#!/usr/bin/env bash
# Forced command for logship keys
# Appends stdin to /srv/logs/<host>/<container>.log.
set -euo pipefail

umask 027 # logs are readable by root and group logs only
LOG_ROOT=/srv/logs
NAME_RE='^[a-z0-9_-]{1,64}$'

host="${1:-}"
name="${SSH_ORIGINAL_COMMAND:-}"

if [[ ! $host =~ $NAME_RE || ! $name =~ $NAME_RE ]]; then
  echo "bad log name" >&2
  exit 1
fi

mkdir -p "$LOG_ROOT/$host"
cat >> "$LOG_ROOT/$host/$name.log"