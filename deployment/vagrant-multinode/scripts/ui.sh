#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed 's/\r$//' /tmp/kyiv-air-common.sh)

require_env ui
install_node
runuser -u vagrant -- env PATH="$PATH" bash -c \
  'set -e; cd "$1"; pnpm install --frozen-lockfile' bash "$SOURCE/ui"
systemctl stop kyiv-air-ui.service 2>/dev/null || true
copy_env ui
set_env ui VITE_API_URL "$HISTORY_URL/api/v1"
wait_http "$HISTORY_URL/health"
pre_start="ExecStartPre=$APP/bin/wait-ready.sh http $HISTORY_URL/health 0 $READY_TIMEOUT"
install_unit vagrant "$SOURCE/ui" \
  "/usr/bin/env pnpm run dev --host 0.0.0.0 --port $SERVICE_PORT --strictPort" "$pre_start"
configure_firewall
start_application
wait_http "http://127.0.0.1:$SERVICE_PORT/"
