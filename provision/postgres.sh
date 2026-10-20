#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=/project/.env
INIT_FILE=/vagrant/init.sql
SETUP_FILE=/vagrant/setup.sql
PGMQ_IMAGE=ghcr.io/pgmq/pg16-pgmq:v1.10.0
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE is missing." >&2; exit 1; }
[[ -f "$INIT_FILE" && -f "$SETUP_FILE" ]] || { echo "ERROR: PostgreSQL schema files are missing." >&2; exit 1; }
env_value() { awk -v key="$1" 'index($0, key "=") == 1 { sub(/^[^=]*=/, ""); sub(/\r$/, ""); print; exit }' "$ENV_FILE"; }
POSTGRES_USER=$(env_value POSTGRES_USER); POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_DB=$(env_value POSTGRES_DB); POSTGRES_DB=${POSTGRES_DB:-history}
POSTGRES_PASSWORD=$(env_value POSTGRES_PASSWORD)
FETCHER_POSTGRES_PASSWORD=$(env_value FETCHER_POSTGRES_PASSWORD)
[[ -n "$POSTGRES_PASSWORD" && -n "$FETCHER_POSTGRES_PASSWORD" ]] || { echo "ERROR: PostgreSQL credentials are required in .env." >&2; exit 1; }

apt-get update
apt-get install -y docker.io curl
systemctl enable --now docker
usermod -aG docker vagrant
docker volume create rabbitmq_data >/dev/null
docker volume create redis_data >/dev/null
docker pull "$PGMQ_IMAGE"

configure_schema() {
    local container=$1
    for attempt in $(seq 1 60); do
        if docker exec "$container" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc 'SELECT 1' >/dev/null 2>&1; then break; fi
        [[ "$attempt" -lt 60 ]] || { echo "ERROR: PostgreSQL $container readiness timeout." >&2; return 1; }
        sleep 2
    done
    docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <"$INIT_FILE"
    docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <"$SETUP_FILE"
    docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        -v "worker_password=$FETCHER_POSTGRES_PASSWORD" <<'SQL'
ALTER ROLE fetcher_worker WITH LOGIN PASSWORD :'worker_password';
SQL
    docker exec "$container" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc \
        "SELECT count(*) FROM pg_extension WHERE extname IN ('hstore','pgmq')" | grep -qx 2
    docker exec "$container" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc \
        "SELECT count(*) FROM pgmq.list_queues() WHERE queue_name='fetcher_tasks'" | grep -qx 1
}

if ! docker container inspect postgres >/dev/null 2>&1; then
    # If a prior attempt left a volume but no container, keep that volume and
    # initialize a separate one rather than guessing whether it contains data.
    if docker volume inspect postgres_data >/dev/null 2>&1; then
        stamp=$(date -u +%Y%m%dT%H%M%SZ)
        new_volume="postgres_data_pgmq_$stamp"
    else
        new_volume=postgres_data
    fi
    docker volume create "$new_volume" >/dev/null
    docker run -d --name postgres --restart unless-stopped --env-file "$ENV_FILE" \
        -p 5432:5432 -v "$new_volume":/var/lib/postgresql/data "$PGMQ_IMAGE" >/dev/null
    configure_schema postgres
    echo "Initialized fresh PGMQ database on volume $new_volume. Any pre-existing volumes were retained."
elif [[ "$(docker inspect --format '{{.Config.Image}}' postgres)" != "$PGMQ_IMAGE" ]]; then
    # Fresh active database requested: keep the old container and volume intact
    # and bring up a separate PGMQ volume. No old volume is mounted to the new image.
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    backup_dir=/var/backups/datafetcher
    install -d -m 700 "$backup_dir"
    backup_file="$backup_dir/history-before-pgmq-$stamp.dump"
    docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
        pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc >"$backup_file"
    chmod 600 "$backup_file"
    docker cp "$backup_file" "postgres:/tmp/history-backup-$stamp.dump" >/dev/null
    docker exec postgres pg_restore --list "/tmp/history-backup-$stamp.dump" >/dev/null

    new_volume="postgres_data_pgmq_$stamp"
    docker volume create "$new_volume" >/dev/null
    candidate="postgres-pgmq-fresh-$stamp"
    docker run -d --name "$candidate" --restart=no --env-file "$ENV_FILE" \
        -v "$new_volume":/var/lib/postgresql/data "$PGMQ_IMAGE" >/dev/null
    if ! configure_schema "$candidate"; then
        echo "ERROR: Fresh PGMQ database initialization failed. Old PostgreSQL and all volumes were retained; candidate: $candidate ($new_volume)." >&2
        exit 1
    fi
    # Assert the active dataset really starts empty before switching service name.
    for table in history user_preferences fetcher_tasks; do
        count=$(docker exec "$candidate" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT count(*) FROM $table")
        [[ "$count" == 0 ]] || { echo "ERROR: Expected an empty $table table; leaving old database active." >&2; exit 1; }
    done
    docker stop "$candidate" >/dev/null

    old_name="postgres-before-pgmq-$stamp"
    docker stop postgres >/dev/null
    docker rename postgres "$old_name"
    if ! docker run -d --name postgres --restart unless-stopped --env-file "$ENV_FILE" \
        -p 5432:5432 -v "$new_volume":/var/lib/postgresql/data "$PGMQ_IMAGE" >/dev/null; then
        docker rename "$old_name" postgres
        docker start postgres >/dev/null
        echo "ERROR: Could not start PGMQ PostgreSQL; restored the original container. Both volumes remain intact." >&2
        exit 1
    fi
    if ! configure_schema postgres; then
        if ! docker logs --tail 60 postgres >&2; then
            echo "WARNING: could not collect logs from the failed PGMQ container." >&2
        fi
        if docker container inspect postgres >/dev/null 2>&1; then
            if ! docker rm -f postgres >/dev/null; then
                echo "ERROR: could not remove the failed PGMQ container; the old container and volumes remain available." >&2
                exit 1
            fi
        fi
        docker rename "$old_name" postgres
        docker start postgres >/dev/null
        echo "ERROR: PGMQ PostgreSQL failed after switch; original PostgreSQL container restored. Volumes retained." >&2
        exit 1
    fi
    echo "Fresh PGMQ database active. Previous container: $old_name; previous volume retained; verified backup: $backup_file"
else
    configure_schema postgres
fi

for name in rabbitmq redis; do
    if docker container inspect "$name" >/dev/null 2>&1; then
        docker start "$name" >/dev/null
        continue
    fi
    if [[ "$name" == rabbitmq ]]; then
        rabbit_url=$(env_value RABBITMQ_URL)
        rabbit_user=${rabbit_url#*://}; rabbit_user=${rabbit_user%%:*}
        rabbit_pass=${rabbit_url#*://}; rabbit_pass=${rabbit_pass#*:}; rabbit_pass=${rabbit_pass%%@*}
        docker run -d --name rabbitmq --restart unless-stopped \
            -e RABBITMQ_DEFAULT_USER="${rabbit_user:-datamonitor}" \
            -e RABBITMQ_DEFAULT_PASS="${rabbit_pass:-datamonitor}" \
            -p 192.168.56.13:5672:5672 -v rabbitmq_data:/var/lib/rabbitmq rabbitmq:3.13-alpine >/dev/null
    else
        docker run -d --name redis --restart unless-stopped \
            -p 192.168.56.13:6379:6379 -v redis_data:/data \
            redis:7-alpine redis-server --appendonly yes >/dev/null
    fi
done
echo "PostgreSQL, HSTORE, PGMQ queue, worker role and broker containers are ready."
