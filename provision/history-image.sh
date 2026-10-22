#!/usr/bin/env bash
# Provisioning of history-vm, step "history-image": builds the Docker image of History
# (API + UI) from the code that Vagrant copied. The container is (re)created by the next
# step, provision/history.sh, so a switch of app_mode does not need a new build.
# Docker itself is installed before this script by provision/docker.sh.
# If the build fails, set -e stops here and the running container keeps working.
set -euo pipefail

IMAGE=weather-history:local
# The build context: the code that Vagrant copied (history/, ui/ and .dockerignore).
BUILD_DIR=/home/vagrant/weather-history

docker build --file "$BUILD_DIR/history/Dockerfile" --tag "$IMAGE" "$BUILD_DIR"

# Each build leaves the previous image without a name ("dangling"); only those are removed.
# An image that a container still uses is not removed.
docker image prune --force >/dev/null
echo "Image $IMAGE is built"
