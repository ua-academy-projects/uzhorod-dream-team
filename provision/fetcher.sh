#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=/project/.env
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE is missing." >&2; exit 1; }
backend=$(awk -F= '$1=="APP_BACKEND" {gsub(/\r/, "", $2); print $2; exit}' "$ENV_FILE")
backend=${backend:-hybrid}
[[ "$backend" == hybrid || "$backend" == postgres ]] || { echo "ERROR: APP_BACKEND must be hybrid or postgres." >&2; exit 1; }

apt-get update
apt-get install -y docker.io curl
systemctl enable --now docker
usermod -aG docker vagrant
cd /vagrant
docker build -t fetcher-app .
if docker container inspect fetcher-service >/dev/null 2>&1; then docker rm -f fetcher-service >/dev/null; fi
docker run -d --name fetcher-service --restart unless-stopped \
    --env-file "$ENV_FILE" --network host fetcher-app >/dev/null
for attempt in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:8000/health >/dev/null; then
        echo "Fetcher container is running with APP_BACKEND=$backend."
        exit 0
    fi
    sleep 2
done
docker logs --tail 60 fetcher-service >&2
echo "ERROR: Fetcher did not stay running." >&2
exit 1
