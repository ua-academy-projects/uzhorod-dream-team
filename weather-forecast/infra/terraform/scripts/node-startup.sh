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

install -d -m 755 /var/lib/weather-forecast /etc/weather-forecast /etc/ssh/sshd_config.d /etc/systemd/system/ssh.socket.d /run/sshd

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

if ! command -v docker >/dev/null; then
  tries=0
  until curl -fsS --max-time 5 -o /dev/null https://download.docker.com/linux/ubuntu/gpg; do
    tries=$((tries + 1))
    [[ $tries -le 60 ]] || { echo 'no internet via bastion' >&2; exit 1; }
    sleep 10
  done
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  install -d /etc/docker
  printf '{\n  "mtu": 1460\n}\n' > /etc/docker/daemon.json
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
fi
systemctl enable --now docker

touch /var/lib/weather-forecast/bootstrap-done
