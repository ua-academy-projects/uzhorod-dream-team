#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed 's/\r$//' /tmp/kyiv-air-docker.sh)
trap cleanup_uploads EXIT
SOURCE=$APP/source
HELPERS=$APP/helpers
DB_HOST=$DB_IP
REDIS_HOST=$DB_IP
RABBITMQ_HOST=$DB_IP
install -d -m 0755 "$HELPERS"
install -m 0644 /tmp/kyiv-air-images.env "$HELPERS/images.env"
install -m 0755 /tmp/kyiv-air-docker-firewall.sh "$HELPERS/docker-firewall.sh"
