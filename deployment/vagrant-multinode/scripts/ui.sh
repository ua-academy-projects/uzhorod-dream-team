#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed 's/\r$//' /tmp/kyiv-air-common.sh)
require_env ui
install_docker
build_image ui "$UI_IMAGE"
configure_firewall
ensure_network
wait_command "History VM at $HISTORY_URL (complete History provisioning before UI)" \
  curl -fsS --connect-timeout 2 --max-time 3 "$HISTORY_URL/health"
start_ui
