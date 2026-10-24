#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive


apt-get update
apt-get install -y ca-certificates curl docker.io

systemctl enable --now docker

apt-get install -y docker-compose-v2 || \
  apt-get install -y docker-compose-plugin

docker --version
docker compose version

echo "=== Docker installation completed ==="