#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed 's/\r$//' /tmp/kyiv-air-common.sh)
read_database
read_rabbitmq
install_docker
configure_firewall
ensure_network
prepare_db_environment
start_databases
