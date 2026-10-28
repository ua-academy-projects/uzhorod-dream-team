#!/usr/bin/env bash
set -Eeuo pipefail

readonly COLLECTOR_USER=log-collector
readonly COLLECTOR_HOME=/home/log-collector
readonly SSH_DIRECTORY_MODE=0700
readonly PRIVATE_FILE_MODE=0600
readonly SUDOERS_FILE_MODE=0440

if (( $# != 2 )); then
  echo "Usage: sudo bash $0 <db-internal-ip> <collector-public-key-file>" >&2
  exit 1
fi

(( EUID == 0 )) || { echo 'Run this script with sudo.' >&2; exit 1; }
db_ip=$1
public_key_file=$2
[[ "$db_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo 'Invalid DB IPv4 address.' >&2; exit 1; }
IFS=. read -r -a octets <<< "$db_ip"
for octet in "${octets[@]}"; do
  (( 10#$octet <= 255 )) || { echo 'Invalid DB IPv4 address.' >&2; exit 1; }
done
ssh-keygen -lf "$public_key_file" >/dev/null
mapfile -t public_key_lines < "$public_key_file"
(( ${#public_key_lines[@]} == 1 )) || { echo 'Provide exactly one public key.' >&2; exit 1; }
public_key=${public_key_lines[0]%$'\r'}
[[ "$public_key" == ssh-ed25519\ * ]] || { echo 'Provide the collector Ed25519 public key.' >&2; exit 1; }
docker_path=$(command -v docker)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf '%s ALL=(root) NOPASSWD: %s logs *\n' "$COLLECTOR_USER" "$docker_path" > "$work/sudoers"
visudo -cf "$work/sudoers"

if ! id "$COLLECTOR_USER" >/dev/null 2>&1; then
  useradd --create-home --user-group --home-dir "$COLLECTOR_HOME" --shell /bin/bash "$COLLECTOR_USER"
fi
[[ $(getent passwd "$COLLECTOR_USER" | cut -d: -f6) == "$COLLECTOR_HOME" ]] || {
  echo "Existing $COLLECTOR_USER account must use $COLLECTOR_HOME." >&2
  exit 1
}
install -d -m "$SSH_DIRECTORY_MODE" -o "$COLLECTOR_USER" -g "$COLLECTOR_USER" "$COLLECTOR_HOME/.ssh"
printf 'from="%s",restrict %s\n' "$db_ip" "$public_key" > "$work/authorized_keys"
install -m "$PRIVATE_FILE_MODE" -o "$COLLECTOR_USER" -g "$COLLECTOR_USER" \
  "$work/authorized_keys" "$COLLECTOR_HOME/.ssh/authorized_keys"
install -m "$SUDOERS_FILE_MODE" -o root -g root "$work/sudoers" /etc/sudoers.d/kyiv-air-log-collector

echo "Installed $COLLECTOR_USER; public-key access is restricted to $db_ip."
