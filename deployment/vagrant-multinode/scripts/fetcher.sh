#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed 's/\r$//' /tmp/kyiv-air-common.sh)
validate_fetcher
read_rabbitmq
install_docker
build_image fetcher "$FETCHER_IMAGE"
configure_firewall
ensure_network
prepare_fetcher_environment
wait_dependencies
start_backend fetcher "$FETCHER_IMAGE" 8080
