#!/bin/bash

set -euo pipefail

for machine in "$@"; do
    printf -v result '\n============= %s =============\n' "$machine"
    printf -v line "%-25s %-20s\n\n" "CONTAINER" "IMAGE SIZE"
    result+="$line"

    container_names=$(ssh "$machine" "sudo docker ps --format '{{.Names}}'")

    IFS=$'\n'
    for container in $container_names; do        
        size=$(ssh "$machine" "
            image=\$(sudo docker inspect '$container' --format '{{.Config.Image}}') &&
            sudo docker image inspect \"\$image\" --format '{{.Size}}' |
                numfmt --to=iec
        ")

        
        printf -v line "%-25s %-20s\n" "$container" "$size"
        result+="$line"
    done
    unset IFS

    printf -v line '%s\n' "===================================="
    result+="$line"

    printf '%s' "$result"
done