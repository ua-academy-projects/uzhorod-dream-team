#!/usr/bin/env bash
set -Eeuo pipefail

: "${SSH_PORT:?Set SSH_PORT in the startup environment.}"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || { echo "Invalid SSH_PORT" >&2; exit 1; }

fail() { echo "$*" >&2; exit 1; }

configure_ssh() {
  install -d -m 0755 /etc/ssh/sshd_config.d
  sed -i -E '/^[[:space:]]*Port[[:space:]]+/d' /etc/ssh/sshd_config
  local snippet
  for snippet in /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$snippet" ]] || continue
    sed -i -E '/^[[:space:]]*Port[[:space:]]+/d' "$snippet"
  done
  printf 'Port %s\n' "$SSH_PORT" > /etc/ssh/sshd_config.d/00-kyiv-air-port.conf
  chmod 0644 /etc/ssh/sshd_config.d/00-kyiv-air-port.conf
  /usr/sbin/sshd -t
  systemctl daemon-reload
  if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
    systemctl restart ssh.socket
  fi
  systemctl restart ssh.service
}

(( EUID == 0 )) || fail "Run this script with sudo."
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then configure_ssh; fi
