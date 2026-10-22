#!/bin/bash

set -euo pipefail

source /vagrant/scripts/utils.sh

for machine in "$@"; do
    ip=$(get_ip "$machine")

    printf '%s: %s\n' "$machine" "$ip"
done