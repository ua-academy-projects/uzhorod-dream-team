#!/usr/bin/env bash
set -euo pipefail

KEY="$HOME/.ssh/iss_tracker_ed25519"
HOSTS_DIR="$HOME/.ssh/iss_tracker"
KNOWN_HOSTS="$HOME/.ssh/iss_tracker_known_hosts"
INCLUDE="Include iss_tracker/*.conf"

install -d -m 700 "$HOME/.ssh" "$HOSTS_DIR"

forget_host() {
  ssh-keygen -R "$1" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
  rm -f "$KNOWN_HOSTS.old"
}

case ${1:-} in
  key)
    [[ -f $KEY ]] || ssh-keygen -q -t ed25519 -N '' -C "iss-tracker@$(hostname)" -f "$KEY"
    mkdir -p .vagrant
    cp "$KEY.pub" .vagrant/iss_tracker_ed25519.pub
    echo "SSH key: $KEY"
    ;;
  collector-key)
    mkdir -p .vagrant
    [[ -f .vagrant/log_collector_ed25519 ]] \
      || ssh-keygen -q -t ed25519 -N '' -C iss-log-collector -f .vagrant/log_collector_ed25519
    echo "log collector key: .vagrant/log_collector_ed25519"
    ;;
  host)
    name=$2 ip=$3 user=$4 proxy=${5:-}
    {
      cat <<EOF
Host $name $ip
  HostName $ip
  User $user
  IdentityFile $KEY
  IdentitiesOnly yes
  UserKnownHostsFile $KNOWN_HOSTS
  StrictHostKeyChecking accept-new
  LogLevel ERROR
EOF
      if [[ -n $proxy ]]; then printf '  ProxyJump %s\n' "$proxy"; fi
    } > "$HOSTS_DIR/$name.conf"
    chmod 600 "$HOSTS_DIR/$name.conf"
    if ! grep -qxF "$INCLUDE" "$HOME/.ssh/config" 2>/dev/null; then
      { printf '%s\n\n' "$INCLUDE"; cat "$HOME/.ssh/config" 2>/dev/null || true; } > "$HOME/.ssh/config.tmp"
      mv "$HOME/.ssh/config.tmp" "$HOME/.ssh/config"
      chmod 600 "$HOME/.ssh/config"
    fi
    forget_host "$ip"
    echo "ready: ssh $name ($user@$ip${proxy:+ via $proxy})"
    ;;
  remove)
    rm -f "$HOSTS_DIR/$2.conf"
    forget_host "$3"
    echo "removed: ssh $2"
    ;;
  *)
    echo "usage: $0 key | collector-key | host <name> <ip> <user> [<proxyjump>] | remove <name> <ip>" >&2
    exit 1
    ;;
esac
