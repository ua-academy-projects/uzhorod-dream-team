#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

sshd_conf=/etc/ssh/sshd_config.d/10-weather.conf
socket_conf=/etc/systemd/system/ssh.socket.d/10-weather-ports.conf
changed=0

md() { curl -fsS -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }

sync_md() {
  local tmp
  tmp=$(mktemp)
  md "$1" > "$tmp"
  if cmp -s "$tmp" "$2"; then
    rm -f "$tmp"
  else
    install -m 644 "$tmp" "$2"
    rm -f "$tmp"
    changed=1
  fi
}

install -d -m 755 /var/lib/weather-forecast /etc/ssh/sshd_config.d /etc/systemd/system/ssh.socket.d /run/sshd

id jump >/dev/null 2>&1 || useradd --create-home --user-group --shell /usr/sbin/nologin jump
install -d -m 700 -o jump -g jump /home/jump/.ssh
md jump-pubkey | install -m 600 -o jump -g jump /dev/stdin /home/jump/.ssh/authorized_keys

sync_md sshd-conf "$sshd_conf"
sync_md socket-conf "$socket_conf"
if [[ $changed -eq 1 ]]; then
  if ! sshd -t; then
    rm -f "$sshd_conf" "$socket_conf"
    echo 'invalid sshd config, defaults kept' >&2
    exit 1
  fi
  systemctl daemon-reload
  systemctl restart ssh.socket ssh.service
fi

command -v nft >/dev/null || { apt-get update; apt-get install -y nftables; }
printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/90-weather-gateway.conf
sysctl -p /etc/sysctl.d/90-weather-gateway.conf >/dev/null
md nft-conf > /etc/nftables.conf
nft --check --file /etc/nftables.conf
systemctl enable nftables.service
nft --file /etc/nftables.conf

touch /var/lib/weather-forecast/bootstrap-done
