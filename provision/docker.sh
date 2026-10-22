#!/usr/bin/env bash
# Docker in a VM: the package docker.io from the standard Ubuntu repository
# (no extra repositories). Running it again is safe.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io

# Docker starts after every boot of the VM and then starts the containers
# with a restart policy (docker run --restart).
systemctl enable --now docker.service
docker version --format 'Docker {{.Server.Version}}'
