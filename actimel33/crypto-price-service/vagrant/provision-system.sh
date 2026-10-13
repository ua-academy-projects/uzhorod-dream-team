#!/usr/bin/env bash
# Every role runs a container: only Docker is installed.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v docker >/dev/null 2>&1; then
  # The first boot often holds the dpkg lock: wait for it instead of failing.
  apt_get() { apt-get -o DPkg::Lock::Timeout=300 -qq "$@"; }
  apt_get update
  install -m 0755 -d /etc/apt/keyrings
  # Plain download, no gpg --dearmor: re-runnable after a partial first run.
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt_get update
  apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin >/dev/null
fi

# Cap local container logs; the central copy lives on db.
DAEMON_JSON='{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}'
if [ "$(cat /etc/docker/daemon.json 2>/dev/null)" != "$DAEMON_JSON" ]; then
  mkdir -p /etc/docker
  echo "$DAEMON_JSON" > /etc/docker/daemon.json
  systemctl restart docker
fi
systemctl enable --now docker
docker --version