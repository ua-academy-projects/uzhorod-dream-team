#!/usr/bin/env bash
# Provisioning of fetcher-vm, step "fetcher-image": builds the Docker image of Fetcher
# from the code that Vagrant copied. The container is (re)created by the next step,
# provision/fetcher.sh, so a switch of app_mode does not need a new build.
# Docker itself is installed before this script by provision/docker.sh.
# If the build fails, set -e stops here and the running container keeps working.
set -euo pipefail

IMAGE=weather-fetcher:local
# The build folder: the code that Vagrant copied (without .env and .venv).
BUILD_DIR=/home/vagrant/weather-history/fetcher

docker build --tag "$IMAGE" "$BUILD_DIR"

# Each build leaves the previous image without a name ("dangling"); only those are removed.
# An image that a container still uses is not removed.
docker image prune --force >/dev/null
echo "Image $IMAGE is built"
