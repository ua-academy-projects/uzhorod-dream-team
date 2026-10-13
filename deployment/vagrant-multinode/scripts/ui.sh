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
copy_env ui
set_env ui HISTORY_URL "$HISTORY_URL"
ports=(-p "$PRIVATE_IP:80:8080" -p 127.0.0.1:80:8080)
replace_container kyiv-air-ui "${ports[@]}" --env-file "$CONFIG/ui.env" "$UI_IMAGE"
wait_http http://127.0.0.1/
wait_http http://127.0.0.1/api/v1/session
