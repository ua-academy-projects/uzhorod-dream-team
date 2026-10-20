#!/bin/bash

set -euo pipefail

source /vagrant/scripts/utils.sh

for machine in "$@"; do
    local ip=$(get_ip "$machine")

    printf '%s: %s\n' "$machine" "$ip"
done