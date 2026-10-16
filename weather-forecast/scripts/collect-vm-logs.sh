#!/usr/bin/env bash
set -euo pipefail
umask 077

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_ROOT="${PROJECT_ROOT}/logs"
STATE_ROOT="${LOG_ROOT}/.state"

VMS=(db fetcher history ui)

declare -A CONTAINERS=(
  [db]="weather-postgres weather-rabbitmq weather-redis"
  [fetcher]="weather-fetcher"
  [history]="weather-history"
  [ui]="weather-ui"
)

SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=1
)

mkdir -p "$STATE_ROOT"

exec 9>"$STATE_ROOT/collector.lock"
if ! flock -n 9; then
  printf 'Another log collection is already running; skipping.\n'
  exit 0
fi

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

remote_ssh() {
  local vm="$1"
  shift
  timeout 60s ssh "${SSH_OPTS[@]}" "$vm" "$@"
}

hash_key() {
  printf '%s' "${1:-initial}" | sha256sum | cut -c1-16
}

write_state() {
  local state_file="$1"
  local value="$2"
  local temp_file

  temp_file="$(mktemp "${state_file}.XXXXXX")"
  printf '%s\n' "$value" >"$temp_file"
  mv -f -- "$temp_file" "$state_file"
}

collect_journal() {
  local vm="$1"
  local source_dir="${LOG_ROOT}/${vm}/system"
  local state_file="${STATE_ROOT}/${vm}/journal.cursor"
  local old_cursor=""
  local next_cursor
  local batch_key
  local raw_file
  local data_file

  mkdir -p "$source_dir" "$(dirname "$state_file")"

  if [[ -s "$state_file" ]]; then
    old_cursor="$(<"$state_file")"
  fi

  batch_key="$(hash_key "${old_cursor:-initial}")"
  raw_file="$(mktemp "${source_dir}/.journal-${batch_key}.raw.XXXXXX")"
  data_file="$(mktemp "${source_dir}/.journal-${batch_key}.data.XXXXXX")"

  if [[ -n "$old_cursor" ]]; then
    if ! printf '%s\n' "$old_cursor" |
      remote_ssh "$vm" \
        'IFS= read -r cursor || exit 2; sudo -n journalctl --quiet --utc --no-pager --show-cursor --after-cursor="$cursor" --output=short-iso-precise' \
        >"$raw_file"; then
      rm -f -- "$raw_file" "$data_file"
      return 1
    fi
  else
    if ! remote_ssh "$vm" \
      'sudo -n journalctl --quiet --utc --no-pager --show-cursor --since "14 days ago" --output=short-iso-precise' \
      >"$raw_file"; then
      rm -f -- "$raw_file" "$data_file"
      return 1
    fi
  fi

  if [[ ! -s "$raw_file" ]]; then
    rm -f -- "$raw_file" "$data_file"
    printf 'No system journal entries returned by %s.\n' "$vm"
    return 0
  fi

  next_cursor="$(sed -n 's/^-- cursor: //p' "$raw_file" | tail -n 1)"
  if [[ -z "$next_cursor" ]]; then
    rm -f -- "$raw_file" "$data_file"
    warn "journalctl did not return a cursor for ${vm}"
    return 1
  fi

  sed '$d' "$raw_file" >"$data_file"

  if [[ -s "$data_file" ]]; then
    mv -f -- "$data_file" "${source_dir}/journal-${batch_key}.log"
  else
    rm -f -- "$data_file"
  fi

  rm -f -- "$raw_file"
  write_state "$state_file" "$next_cursor"
  printf 'Collected system journal from %s.\n' "$vm"
}

collect_container() {
  local vm="$1"
  local container="$2"
  local source_dir="${LOG_ROOT}/${vm}/containers/${container}"
  local state_file="${STATE_ROOT}/${vm}/containers/${container}.timestamp"
  local old_timestamp=""
  local since
  local batch_key
  local raw_file
  local data_file
  local next_timestamp

  mkdir -p "$source_dir" "$(dirname "$state_file")"

  if [[ -s "$state_file" ]]; then
    old_timestamp="$(<"$state_file")"
  fi

  if [[ -n "$old_timestamp" ]] &&
     [[ ! "$old_timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$ ]]; then
    warn "invalid Docker log checkpoint for ${vm}/${container}"
    return 1
  fi

  since="${old_timestamp:-336h}"
  batch_key="$(hash_key "${old_timestamp:-initial}")"
  raw_file="$(mktemp "${source_dir}/.docker-${batch_key}.raw.XXXXXX")"
  data_file="$(mktemp "${source_dir}/.docker-${batch_key}.data.XXXXXX")"

  if ! remote_ssh "$vm" \
    "sudo -n docker logs --timestamps --since='${since}' '${container}' 2>&1" \
    >"$raw_file"; then
    rm -f -- "$raw_file" "$data_file"
    return 1
  fi

  awk -v last="$old_timestamp" '
    NF {
      timestamp = $1
      if (last == "" || timestamp > last) {
        print
      }
    }
  ' "$raw_file" >"$data_file"

  # Docker stdout and stderr can arrive out of timestamp order.
  next_timestamp="$(awk 'NF && $1 > latest { latest = $1 } END { print latest }' "$data_file")"

  if [[ -s "$data_file" ]]; then
    if [[ ! "$next_timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$ ]]; then
      rm -f -- "$raw_file" "$data_file"
      warn "Docker returned an unexpected timestamp for ${vm}/${container}"
      return 1
    fi

    mv -f -- "$data_file" "${source_dir}/docker-${batch_key}.log"
    write_state "$state_file" "$next_timestamp"
    printf 'Collected Docker logs from %s/%s.\n' "$vm" "$container"
  else
    rm -f -- "$data_file"
    printf 'No new Docker logs from %s/%s.\n' "$vm" "$container"
  fi

  rm -f -- "$raw_file"
}

compress_and_prune_tree() {
  local root="$1"

  [[ -d "$root" ]] || return 0

  find "$root" -type f -name '*.log' -mmin +1440 -exec gzip -f -- {} +
  find "$root" -type f -name '*.log.gz' -mmin +20160 -exec rm -f -- {} +
}

compress_and_prune() {
  local old_dir

  compress_and_prune_tree "$LOG_ROOT"

  shopt -s nullglob
  for old_dir in "${PROJECT_ROOT}"/logs-*.old; do
    compress_and_prune_tree "$old_dir"
  done
  shopt -u nullglob
}

failures=0

printf 'Log collection started at %s UTC.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

for vm in "${VMS[@]}"; do
  printf '\n=== %s ===\n' "$vm"

  if ! timeout 12s ssh "${SSH_OPTS[@]}" "$vm" 'sudo -n true'; then
    warn "${vm} is unavailable; skipping it without advancing checkpoints"
    failures=1
    continue
  fi

  if ! collect_journal "$vm"; then
    warn "system journal collection failed for ${vm}"
    failures=1
  fi

  read -r -a vm_containers <<<"${CONTAINERS[$vm]}"
  for container in "${vm_containers[@]}"; do
    if ! collect_container "$vm" "$container"; then
      warn "Docker log collection failed for ${vm}/${container}"
      failures=1
    fi
  done
done

if ! compress_and_prune; then
  warn "compression or log retention cleanup failed"
  failures=1
fi

printf '\nLog collection finished at %s UTC.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if (( failures > 0 )); then
  exit 1
fi
