#!/bin/bash
set -euo pipefail

RETENTION_DAYS=7
LOG_DIR="/var/log/remote"
SSH_KEY="/home/vagrant/.ssh/logfetcher"

mkdir -p "$LOG_DIR"

find "$LOG_DIR" -maxdepth 1 -type f -name '*.tar.gz' \
    -mtime +"$RETENTION_DAYS" -delete

while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" != *_HOST=* ]] && continue

    VM="${line%%_HOST=*}"
    VM="${VM,,}"

    VM_HOST="${line#*_HOST=}"

    TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
    ARCHIVE="$LOG_DIR/${TIMESTAMP}-${VM}.tar.gz"
    TEMP_DIR=$(mktemp -d)

    if ssh -n \
        -i "$SSH_KEY" \
        -o IdentitiesOnly=yes \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=yes \
        "vagrant@$VM_HOST" \
        "CONTAINER_ID=\$(sudo docker ps -q --filter name=^/${VM}$ | head -n 1)
        if [ -n \"\$CONTAINER_ID\" ]; then
            sudo docker logs --since 15m \"\$CONTAINER_ID\" 2>&1
        else
            echo 'Container not found: ${VM}' >&2
            exit 1
        fi" \
        > "$TEMP_DIR/${VM}.log" 2>&1; then

        tar -czf "$ARCHIVE" -C "$TEMP_DIR" "${VM}.log"
        echo "Collected logs from $VM: $ARCHIVE"
    else
        echo "Failed to collect logs from $VM" >&2
        cat "$TEMP_DIR/${VM}.log" >&2
    fi

    rm -rf "$TEMP_DIR"
done < /etc/vm_hosts.env
