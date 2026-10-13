#!/usr/bin/env bash
set -uo pipefail

readonly PRIVATE_FILE_UMASK=077
umask "$PRIVATE_FILE_UMASK"

readonly CONFIG=/etc/kyiv-air-logging
readonly STATE=/var/lib/kyiv-air-log-collector
readonly ARCHIVE=/var/log/kyiv-air-aggregated
readonly INITIAL_LOOKBACK_SECONDS=900
readonly OVERLAP_SECONDS=1
readonly RETENTION_DAYS=7
readonly SSH_CONNECT_TIMEOUT_SECONDS=10
readonly EXPORT_TIMEOUT_SECONDS=120
readonly MAX_TIMESTAMP_DIGITS=12

[[ -f "$CONFIG/logging.enabled" ]] || exit 0
[[ -s "$CONFIG/sources.tsv" ]] || { echo 'Missing logging sources' >&2; exit 1; }
exec 9>"$STATE/collector.lock" || exit 1

flock -n 9 || exit 0

end=$(date +%s)
failed=0

collect() {
  local vm=$1 ip=$2 container=$3 since directory checkpoint file
  checkpoint=$STATE/$vm-$container.timestamp
  since=$((end - INITIAL_LOOKBACK_SECONDS))
  if [[ -f "$checkpoint" ]]; then
    read -r since < "$checkpoint" || return 1
    [[ "$since" =~ ^[0-9]{1,$MAX_TIMESTAMP_DIGITS}$ ]] || return 1
    since=$((10#$since - OVERLAP_SECONDS))
  fi
  (( since >= 0 && since <= end )) || return 1
  directory=$ARCHIVE/$vm/$container
  mkdir -p "$directory" || return 1
  file=$directory/$(date -u -d "@$end" +%Y%m%dT%H%M%SZ).log
  if [[ "$vm" == db ]]; then
    timeout "$EXPORT_TIMEOUT_SECONDS" docker logs --timestamps --since "$since" --until "$end" "$container" > "$file.tmp" 2>&1 || return 1
  else
    timeout "$EXPORT_TIMEOUT_SECONDS" ssh -n -T -i "$STATE/id_ed25519" \
      -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
      -o "UserKnownHostsFile=$STATE/known_hosts" -o GlobalKnownHostsFile=/dev/null \
      -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT_SECONDS" "vagrant@$ip" \
      "sudo -n docker logs --timestamps --since $since --until $end $container 2>&1" > "$file.tmp" || return 1
  fi
  gzip -c "$file.tmp" > "$file.gz.tmp" || return 1
  mv "$file.gz.tmp" "$file.gz" || return 1
  printf '%s\n' "$end" > "$checkpoint.tmp" || return 1
  mv "$checkpoint.tmp" "$checkpoint" || return 1
  rm -f "$file.tmp"
  echo "$(date -u +%FT%TZ) collected $vm/$container ($since..$end)"
}

while read -r vm ip container; do
  [[ "$vm" =~ ^(db|fetcher|history|ui|bastion)$ && "$ip" =~ ^[0-9.]+$ && "$container" =~ ^kyiv-air-(postgres|redis|rabbitmq|fetcher|history|ui|bastion)$ ]] || { failed=1; continue; }
  if ! collect "$vm" "$ip" "$container"; then
    echo "$(date -u +%FT%TZ) failed $vm/$container; checkpoint retained" >&2
    rm -f "$ARCHIVE/$vm/$container/"*.tmp "$STATE/$vm-$container.timestamp.tmp"
    failed=1
  fi
done < "$CONFIG/sources.tsv"

find "$ARCHIVE" -type f -name '*.gz' -mtime "+$((RETENTION_DAYS - 1))" -delete || failed=1

exit "$failed"
