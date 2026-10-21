#!/usr/bin/env bash
# Log collector (db): cron pulls journald logs of the fetcher, history and the bastion nginx over SSH
# (see logpull-target.sh for the other side). The private key is uploaded to /tmp/logpull_key. Idempotent.
set -euo pipefail

DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cron logrotate

id logpull &>/dev/null || useradd --system --create-home --shell /usr/sbin/nologin logpull
install -d -m700 -o logpull -g logpull /home/logpull/.ssh
install -m600 -o logpull -g logpull /tmp/logpull_key /home/logpull/.ssh/id_ed25519
rm -f /tmp/logpull_key
# setgid: files created by the collector are group-readable by "adm"
install -d -m2750 -o logpull -g adm /var/log/reload
install -d -m750 -o logpull -g logpull /var/lib/logpull

# <ip> <selector> <file under /var/log/reload>; one line per log source
cat >/etc/logpull.conf <<'CONF'
10.10.0.21 unit:fetcher fetcher/fetcher.log
10.10.0.22 unit:history history/history.log
10.10.0.10 tag:nginx_access bastion/nginx-access.log
10.10.0.10 tag:nginx_error bastion/nginx-error.log
CONF

cat >/usr/local/bin/logpull <<'PULL'
#!/usr/bin/env bash
# Appends new journal lines of every source in /etc/logpull.conf to /var/log/reload. The journald cursor of the last
# pulled entry is kept in /var/lib/logpull, so lines are neither lost nor repeated between runs.
set -uo pipefail
umask 027
OUT=/var/log/reload
STATE=/var/lib/logpull
log() { echo "$(date -Is) $*" >>"$OUT/logpull.log"; }

while read -r ip selector file; do
  [[ -z "$ip" || "$ip" == \#* ]] && continue
  cursor_file="$STATE/${ip}_${selector//[^A-Za-z0-9_]/_}.cursor"
  cursor=$(cat "$cursor_file" 2>/dev/null || true)
  tmp=$(mktemp)

  # -n: otherwise ssh swallows the rest of /etc/logpull.conf from the loop's stdin
  ssh -n -i "$HOME/.ssh/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      "logpull@$ip" "$selector $cursor" >"$tmp" 2>"$tmp.err"
  rc=$?
  if [ $rc -ne 0 ]; then
    log "$ip $selector: failed (rc=$rc): $(head -c 200 "$tmp.err" | tr '\n' ' ')"
    # 255 = SSH itself failed (keep the cursor); anything else is journalctl, most likely a stale cursor
    [ $rc -eq 255 ] || rm -f "$cursor_file"
    rm -f "$tmp" "$tmp.err"
    continue
  fi

  mkdir -p "$OUT/$(dirname "$file")"
  grep -v '^-- ' "$tmp" >>"$OUT/$file"
  log "$ip $selector: +$(grep -vc '^-- ' "$tmp") lines"
  new=$(sed -n 's/^-- cursor: //p' "$tmp" | tail -n1)
  # the cursor is stored after the append: a crash in between repeats lines, but never loses them
  if [ -n "$new" ]; then printf '%s' "$new" >"$cursor_file.tmp" && mv "$cursor_file.tmp" "$cursor_file"; fi
  rm -f "$tmp" "$tmp.err"
done </etc/logpull.conf
PULL
chmod 755 /usr/local/bin/logpull

cat >/etc/cron.d/logpull <<'CRON'
PATH=/usr/local/bin:/usr/bin:/bin
*/15 * * * * logpull flock -n /var/lib/logpull/lock /usr/local/bin/logpull
CRON
chmod 644 /etc/cron.d/logpull

cat >/etc/logrotate.d/reload <<'ROTATE'
/var/log/reload/*.log /var/log/reload/*/*.log {
  daily
  rotate 14
  compress
  delaycompress
  missingok
  notifempty
  create 0640 logpull adm
}
ROTATE

systemctl enable cron
systemctl restart cron
