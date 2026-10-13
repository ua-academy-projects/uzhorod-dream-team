#!/usr/bin/env bash
set -Eeuo pipefail

readonly VAGRANT_TIMEOUT_SECONDS=180

cd "$(dirname "${BASH_SOURCE[0]}")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

remote() { timeout "$VAGRANT_TIMEOUT_SECONDS" vagrant ssh "$1" -c "$2" </dev/null | tr -d '\r'; }

remote db 'sudo rm -f /etc/kyiv-air-logging/logging.enabled'
remote db 'sudo cat /etc/kyiv-air-logging/sources.tsv' > "$work/sources"
remote db 'sudo cat /var/lib/kyiv-air-log-collector/id_ed25519.pub' > "$work/collector.pub"

ssh-keygen -lf "$work/collector.pub" >/dev/null
: > "$work/known_hosts"
install_key_command=$(cat <<'SH_REMOTE'
set -eu
install -d -m 0700 /home/vagrant/.ssh
touch /home/vagrant/.ssh/authorized_keys
key=$(cat /tmp/kyiv-air-log-collector.pub)
grep -qxF -- "$key" /home/vagrant/.ssh/authorized_keys || printf '\n%s\n' "$key" >> /home/vagrant/.ssh/authorized_keys
chmod 0600 /home/vagrant/.ssh/authorized_keys
rm -f /tmp/kyiv-air-log-collector.pub
SH_REMOTE
)

while read -r vm ip container; do
  [[ "$vm" != db ]] || continue
  [[ "$vm" =~ ^(fetcher|history|ui|bastion)$ && "$ip" =~ ^[0-9.]+$ && "$container" =~ ^kyiv-air-(fetcher|history|ui|bastion)$ ]] || exit 1
  timeout "$VAGRANT_TIMEOUT_SECONDS" vagrant upload "$work/collector.pub" /tmp/kyiv-air-log-collector.pub "$vm"
  remote "$vm" "$install_key_command"
  remote "$vm" 'sudo cat /etc/ssh/ssh_host_ed25519_key.pub' > "$work/host.pub"
  ssh-keygen -lf "$work/host.pub" >/dev/null
  read -r type key _ < "$work/host.pub"
  printf '%s %s %s\n' "$ip" "$type" "$key" >> "$work/known_hosts"
done < "$work/sources"

timeout "$VAGRANT_TIMEOUT_SECONDS" vagrant upload "$work/known_hosts" /tmp/kyiv-air-log-known-hosts db

remote db 'set -e; sudo install -m 0600 /tmp/kyiv-air-log-known-hosts /var/lib/kyiv-air-log-collector/known_hosts; rm -f /tmp/kyiv-air-log-known-hosts'
remote db 'sudo touch /etc/kyiv-air-logging/logging.enabled'

if ! remote db 'sudo /usr/local/sbin/collect-kyiv-air-logs'; then
  remote db 'sudo rm -f /etc/kyiv-air-logging/logging.enabled'
  echo 'Initial collection failed; scheduled collection is disabled' >&2
  exit 1
fi

echo 'Initial collection succeeded. Cron will collect logs every 15 minutes on DB.'
