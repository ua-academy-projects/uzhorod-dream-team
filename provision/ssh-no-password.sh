#!/usr/bin/env bash
# SSH login only with a key, in every VM (bastion-vm, weather-vm, fetcher-vm, history-vm).
# The box bento/ubuntu-24.04 turns on password login (50-cloud-init.conf: PasswordAuthentication
# yes), and the user vagrant has the well-known password from the box.
# Vagrant itself logs in with its own key (.vagrant/machines/<vm>/virtualbox/private_key),
# so vagrant ssh and provisioning keep working. The user vagrant and its keys are not touched.
# Running it again is safe: the file is written anew every time.
set -euo pipefail

# sshd reads the files of sshd_config.d in alphabetical order, and for these settings the
# first value it finds wins. "05-" comes before "50-cloud-init.conf", so "no" here wins over
# its "yes". 50-cloud-init.conf itself is not edited: cloud-init may write it again.
conf=/etc/ssh/sshd_config.d/05-weather-no-password.conf
cat > "$conf" <<'EOF'
# Written by provision/ssh-no-password.sh (weather-history). Do not edit by hand.
# Only key login: no password, no keyboard-interactive (PAM asks for the password there).
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
EOF
chmod 0644 "$conf"

# A broken config would stop sshd and lock out Vagrant too, so it is checked first.
if ! sshd -t; then
  rm -f "$conf"
  echo "sshd config check failed, $conf removed" >&2
  exit 1
fi

# reload: sshd reads the config again, open sessions (also this one) are kept.
systemctl try-reload-or-restart ssh.service

# The values sshd really uses now (also after all Include files).
settings=$(sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|authenticationmethods) ')
echo "$settings"
if ! grep -qx 'passwordauthentication no' <<< "$settings" ||
   ! grep -qx 'kbdinteractiveauthentication no' <<< "$settings" ||
   ! grep -qx 'authenticationmethods publickey' <<< "$settings"; then
  echo "password login is still on, check /etc/ssh/sshd_config.d" >&2
  exit 1
fi
