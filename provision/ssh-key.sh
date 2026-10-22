#!/usr/bin/env bash
# Adds the public SSH key of the project owner to authorized_keys of the user vagrant,
# so that "ssh weather", "ssh fetcher" and "ssh history" work from WSL.
# The key of Vagrant in the same file is kept: vagrant ssh needs it.
# Only the public key comes here; the private key never leaves WSL. Running it again is safe.
set -euo pipefail

if [[ ! "${SSH_PUBLIC_KEY:-}" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+=*(\ [^[:cntrl:]]*)?$ ]]; then
  echo "SSH_PUBLIC_KEY must be one ssh-ed25519 public key" >&2
  exit 1
fi
# Optional: the only address this key may log in from (option from="..." in authorized_keys).
# The internal VMs get the internal address of bastion-vm: then the key works only through
# bastion, not through the NAT ports of Vagrant (127.0.0.1:22xx). Empty on bastion-vm itself.
# The key of Vagrant gets no such option: vagrant ssh and provisioning keep working.
if [[ -n "${SSH_KEY_FROM:-}" && ! "$SSH_KEY_FROM" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "SSH_KEY_FROM must be an IPv4 address or empty" >&2
  exit 1
fi

# Own host keys for this VM, once. The bento box has the same host keys in every VM made
# from it (and everyone who downloads the box has them), so with them the client could not
# tell weather-vm, fetcher-vm, history-vm or a fake server apart.
# vagrant ssh does not check host keys, so it keeps working; ssh-trust.sh in WSL must be
# run again after this, because the keys are new.
marker=/etc/ssh/weather-history-host-keys
if [[ ! -e "$marker" ]]; then
  rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
  ssh-keygen -A
  # sshd reads the host keys when it starts. Open sessions (also this one) are kept.
  systemctl try-restart ssh.service
  date -u +%Y-%m-%dT%H:%M:%SZ > "$marker"
  echo "New SSH host keys generated for $(hostname)"
fi

dir=/home/vagrant/.ssh
file=$dir/authorized_keys

# .ssh: only vagrant may enter (700); authorized_keys: only vagrant may read and write (600).
# sshd ignores authorized_keys if other users may write to it.
install -d -m 0700 -o vagrant -g vagrant "$dir"
touch "$file"
chown vagrant:vagrant "$file"
chmod 0600 "$file"

if [[ -n "${SSH_KEY_FROM:-}" ]]; then
  line="from=\"$SSH_KEY_FROM\" $SSH_PUBLIC_KEY"
else
  line="$SSH_PUBLIC_KEY"
fi

if grep -qxF "$line" "$file"; then
  echo "SSH key of the project owner is already in $file"
else
  # The old line of this key (without from= or with another address) is replaced by the new one.
  # The key is found by its base64 part. Lines of other keys (the key of Vagrant) stay as they are.
  key_base64=$(awk '{ print $2 }' <<< "$SSH_PUBLIC_KEY")
  tmp=$(mktemp "$dir/authorized_keys.XXXXXX")
  awk -v key="$key_base64" '{ for (i = 1; i <= NF; i++) if ($i == key) next; print }' "$file" > "$tmp"
  printf '%s\n' "$line" >> "$tmp"
  chown vagrant:vagrant "$tmp"
  chmod 0600 "$tmp"
  # mv replaces the file at once: sshd never sees a half-written authorized_keys.
  mv "$tmp" "$file"
  echo "SSH key of the project owner written to $file${SSH_KEY_FROM:+ (only from $SSH_KEY_FROM)}"
fi
echo "Keys in $file: $(grep -c . "$file")"
