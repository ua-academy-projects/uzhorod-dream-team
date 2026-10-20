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
# Stream a clean context: Docker's legacy builder cannot stat pytest/venv
# directories on some VirtualBox shared-folder implementations.
tar --exclude='./.pytest_cache' --exclude='./.venv' --exclude='./venv' \
    --exclude='./__pycache__' --exclude='./.env' -cf - . | docker build -t ui-app -
if docker container inspect ui-service >/dev/null 2>&1; then docker rm -f ui-service >/dev/null; fi
docker run -d --name ui-service --restart unless-stopped \
    --env-file "$ENV_FILE" -p 8000:8000 ui-app >/dev/null
for attempt in $(seq 1 45); do
    if curl -fsS http://127.0.0.1:8000/ >/dev/null; then
        echo "UI container is running with APP_BACKEND=$backend."
        exit 0
    fi
    sleep 2
done
docker logs --tail 60 ui-service >&2
echo "ERROR: UI did not stay running." >&2
exit 1
