#!/usr/bin/env bash
# UI machine: nginx serves the built app and proxies /api to history.
set -euo pipefail

. /home/vagrant/app/vagrant/lib.sh
cd /home/vagrant/app

echo "==> image"
sudo docker build -t crypto/ui:latest ui

echo "==> container"
replace crypto_ui \
  -e HISTORY_URL="http://${HISTORY_IP}:3001" -p 5173:8080 \
  crypto/ui:latest
wait_healthy crypto_ui
sudo docker image prune -f >/dev/null

# history builds its image in parallel and may come up minutes later.
wait_port "$HISTORY_IP" 3001

# ui -> nginx -> history -> db.
echo "==> end-to-end"
curl -sf --retry 30 --retry-delay 2 --retry-connrefused http://127.0.0.1:5173/api/health
echo
