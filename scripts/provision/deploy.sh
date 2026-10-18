#!/bin/bash
set -euo pipefail

STAGE=/home/vagrant/iss-config
APP=/opt/iss

trap 'rm -rf "$STAGE"' EXIT

install -d -m 755 "$APP"
install -o root -g root -m 644 "$STAGE/compose.yaml" "$APP/compose.yaml"
install -o root -g root -m 600 "$STAGE/iss.env"      "$APP/.env"

cd "$APP"
docker compose up -d --build --remove-orphans

active=$(docker compose config --services)
for service in $(docker compose --profile '*' config --services); do
  if ! grep -qx "$service" <<< "$active"; then
    docker compose --profile '*' rm --stop --force "$service"
  fi
done

docker image prune -f
