#!/usr/bin/env bash
set -euo pipefail

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  systemctl enable --now docker
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive


apt-get update
apt-get install -y ca-certificates curl docker.io

systemctl enable --now docker

apt-get install -y docker-compose-v2 || \
  apt-get install -y docker-compose-plugin

docker --version
docker compose version

apt-get install -y git

echo "=== Docker installation completed ==="
