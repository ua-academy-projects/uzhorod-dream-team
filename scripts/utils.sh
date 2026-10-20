#!/bin/bash

write_env() {
    local file="$1"
    shift

    for var in "$@"; do
        if [[ "$var" == *=* ]]; then
            printf '%s\n' "$var"
        else
            printf '%s=%s\n' "$var" "${!var}"
        fi
    done | sudo tee "$file" > /dev/null

    sudo chmod 600 "$file"
}

get_ip() {
    local machine="$1"

    ssh "$machine" \
        "ip -4 -o addr show dev eth2 | awk '{print \$4}' | cut -d/ -f1" \
        2>/dev/null | tr -d '\r'
}