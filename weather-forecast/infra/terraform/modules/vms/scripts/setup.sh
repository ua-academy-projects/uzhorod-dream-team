#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

role=${1:?usage: setup.sh bastion|node}

install -d -m 755 /run/sshd
if ! sshd -t; then
  rm -f /etc/ssh/sshd_config.d/10-weather.conf /etc/systemd/system/ssh.socket.d/10-weather-port.conf
  echo 'invalid sshd config, defaults kept' >&2
  exit 1
fi
systemctl daemon-reload
systemctl restart ssh.socket ssh.service

case $role in
  bastion)
    command -v nft >/dev/null || { apt-get update; apt-get install -y nftables; }
    sysctl --system >/dev/null
    nft --check --file /etc/nftables.conf
    systemctl enable nftables.service
    systemctl restart nftables.service
    ;;
  node)
    tries=0
    until curl -fsS --max-time 5 -o /dev/null http://archive.ubuntu.com/ubuntu/; do
      tries=$((tries + 1))
      [[ $tries -lt 60 ]] || { echo 'no internet via bastion' >&2; exit 1; }
      sleep 10
    done
    apt-get update
    apt-get install -y docker.io
    systemctl enable --now docker
    ;;
  *)
    echo "unknown role: $role" >&2
    exit 1
    ;;
esac
