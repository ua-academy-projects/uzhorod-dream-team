#!/usr/bin/env bash
# Brings up the whole environment: the database in a container plus three local
# processes. Ctrl+C stops the processes; the database keeps running
# (stop it with: docker compose stop db).
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p logs bin

if [ ! -f .env ]; then
  echo "No .env file. Copy .env.example and fill in the values." >&2
  exit 1
fi

# Go has no --env-file like node, so the variables go into the environment.
set -a
# shellcheck disable=SC1091
. ./.env
set +a

# Go may live in the home directory when installed without root.
if ! command -v go >/dev/null 2>&1 && [ -x "$HOME/sdk/go/bin/go" ]; then
  export PATH="$PATH:$HOME/sdk/go/bin"
fi
if ! command -v go >/dev/null 2>&1; then
  echo "Go not found. Install it or add it to PATH." >&2
  exit 1
fi

echo "==> database (backend: ${BACKEND:-redis})"
if [ "${BACKEND:-redis}" = redis ]; then
  docker compose up -d --wait db redis
else
  docker compose up -d --wait db
fi

echo "==> building fetcher (Go)"
( cd services/fetcher && go build -buildvcs=false -o ../../bin/fetcher . )

pids=()
cleanup() {
  echo
  echo "==> stopping processes"
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup INT TERM

echo "==> history (logs: logs/history.log)"
( cd services/history && npm run start ) > logs/history.log 2>&1 &
pids+=("$!")

echo "==> fetcher (logs: logs/fetcher.log)"
./bin/fetcher > logs/fetcher.log 2>&1 &
pids+=("$!")

echo "==> ui (logs: logs/ui.log)"
( cd ui && npm run dev ) > logs/ui.log 2>&1 &
pids+=("$!")

cat <<'BANNER'

Ready:
  UI       http://localhost:5173
  History  http://localhost:3001/health
  Fetcher  http://localhost:3002/health

Logs: tail -f logs/*.log        Ctrl+C to stop.
BANNER

wait
