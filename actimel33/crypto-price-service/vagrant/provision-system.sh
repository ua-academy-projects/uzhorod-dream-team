#!/usr/bin/env bash
# Every role runs a container: only Docker is installed.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v docker >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin >/dev/null
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