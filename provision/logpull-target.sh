#!/usr/bin/env bash
# Read-only log access for the collector on db: the "logpull" user whose only allowed SSH command is
# logpull-serve (a few fixed journalctl queries). The public key is uploaded to /tmp/logpull.pub. Idempotent.
set -euo pipefail

COLLECTOR_IP=10.10.0.25 # db

id logpull &>/dev/null || useradd --system --create-home --shell /bin/bash logpull
usermod -aG systemd-journal logpull

cat >/usr/local/bin/logpull-serve <<'SERVE'
#!/bin/bash
# Forced command of the logpull key: "<selector> [cursor]" from $SSH_ORIGINAL_COMMAND, validated against an allowlist.
set -euo pipefail
read -r sel cursor extra <<<"${SSH_ORIGINAL_COMMAND:-}"
[ -z "${extra:-}" ] || { echo "bad request" >&2; exit 2; }
case "$sel" in
  unit:fetcher | unit:history) args=(-u "${sel#unit:}") ;;
  tag:nginx_access | tag:nginx_error) args=(-t "${sel#tag:}") ;;
  *) echo "bad selector" >&2; exit 2 ;;
esac
if [ -n "${cursor:-}" ]; then
  [[ $cursor =~ ^s=[0-9a-f]+\;i=[0-9a-f]+\;b=[0-9a-f]+\;m=[0-9a-f]+\;t=[0-9a-f]+\;x=[0-9a-f]+$ ]] || { echo "bad cursor" >&2; exit 2; }
  args+=(--after-cursor "$cursor")
fi
exec journalctl --no-pager -o short-iso --show-cursor "${args[@]}"
SERVE
chmod 755 /usr/local/bin/logpull-serve

install -d -m700 -o logpull -g logpull /home/logpull/.ssh
printf 'restrict,from="%s",command="/usr/local/bin/logpull-serve" %s\n' "$COLLECTOR_IP" "$(cat /tmp/logpull.pub)" \
  >/home/logpull/.ssh/authorized_keys
chown logpull:logpull /home/logpull/.ssh/authorized_keys
chmod 600 /home/logpull/.ssh/authorized_keys
