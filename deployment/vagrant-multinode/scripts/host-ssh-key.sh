#!/usr/bin/env bash
set -Eeuo pipefail

key_file=/tmp/kyiv-air-host-ssh.pub
trap 'rm -f "$key_file"' EXIT
public_key=$(tr -d '\r' < "$key_file")
[[ -n "$public_key" && "$public_key" != *$'\n'* ]] || {
  echo "Expected one SSH public key in $key_file" >&2
  exit 1
}
ssh-keygen -lf "$key_file" >/dev/null

ssh_dir=/home/vagrant/.ssh
authorized_keys=$ssh_dir/authorized_keys
install -d -m 0700 -o vagrant -g vagrant "$ssh_dir"
touch "$authorized_keys"
if ! grep -qxF -- "$public_key" "$authorized_keys"; then
  printf '\n%s\n' "$public_key" >> "$authorized_keys"
fi
chown vagrant:vagrant "$authorized_keys"
chmod 0600 "$authorized_keys"
