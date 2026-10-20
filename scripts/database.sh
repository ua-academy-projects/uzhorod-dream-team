#!/bin/bash

set -euo pipefail

function wait_until_pg_isready() {
    until sudo docker exec postgres pg_isready \
        -U "$DATABASE_USER" -d postgres > /dev/null 2>&1
    do
        sleep 1
    done
}

function install_pgmq() {
    local sql_file="/tmp/pgmq.sql"
    local installed

    installed=$(sudo docker exec postgres psql \
        -U "$DATABASE_USER" \
        -d "$DATABASE_DB" \
        -tAc "SELECT EXISTS (
            SELECT 1
            FROM pg_namespace
            WHERE nspname = 'pgmq'
        );")

    if [[ "$installed" == "t" ]]; then
        echo "PGMQ schema already exists; skipping installation."
        return
    fi

    if ! sudo docker exec postgres test -f /docker-entrypoint-initdb.d/pgmq.sql; then
        sudo apt update
        sudo apt install -y curl unzip

        curl -fsSL \
            https://github.com/pgmq/pgmq/archive/refs/heads/main.zip \
            -o /tmp/pgmq.zip

        unzip -p /tmp/pgmq.zip \
            pgmq-main/pgmq-extension/sql/pgmq.sql \
            > "$sql_file"

        sudo docker cp "$sql_file" postgres:/docker-entrypoint-initdb.d/pgmq.sql

        rm -rf /tmp/pgmq.zip /tmp/pgmq-main
    fi

    sudo docker exec postgres \
        psql -v ON_ERROR_STOP=1 \
        -U "$DATABASE_USER" \
        -d "$DATABASE_DB" \
        -f /docker-entrypoint-initdb.d/pgmq.sql
}

function install_hstore() {
    sudo docker exec postgres \
        psql -v ON_ERROR_STOP=1 \
        -U "$DATABASE_USER" \
        -d "$DATABASE_DB" \
        -c "
            CREATE EXTENSION IF NOT EXISTS hstore;

            CREATE TABLE IF NOT EXISTS cache (
                attributes HSTORE NOT NULL,
                expires_at timestamptz
            );

            CREATE UNIQUE INDEX IF NOT EXISTS idx_cache_attributes
                ON cache ((attributes -> 'key'));
            CREATE INDEX IF NOT EXISTS idx_cache_expires_at
                ON cache (expires_at);
        "
}

function init_database() {
    sudo docker exec postgres \
        psql -v ON_ERROR_STOP=1 \
        -U "$DATABASE_USER" \
        -d "$DATABASE_DB" \
        -c "
            CREATE TABLE IF NOT EXISTS public.bars (
                id bigint NOT NULL,
                symbol character varying(20) NOT NULL,
                open numeric(20,10) NOT NULL,
                high numeric(20,10) NOT NULL,
                low numeric(20,10) NOT NULL,
                close numeric(20,10) NOT NULL,
                volume numeric(30,10) DEFAULT 0 NOT NULL,
                tick_volume bigint DEFAULT 0 NOT NULL,
                is_open boolean DEFAULT false NOT NULL,
                open_time timestamp with time zone NOT NULL,
                "timestamp" timestamp with time zone DEFAULT now() NOT NULL
            );
        "
}

function restore_database() {
    local snapshot="/vagrant/database/snapshots/2026_10_19.sql"

    sudo docker exec -i postgres \
        dropdb \
        -U "$DATABASE_USER" \
        --if-exists \
        "$DATABASE_DB"

    sudo docker exec -i postgres \
        createdb \
        -U "$DATABASE_USER" \
        "$DATABASE_DB"

    sudo docker exec -i postgres psql \
        -U "$DATABASE_USER" \
        -d "$DATABASE_DB" \
        < "$snapshot"
}

source /vagrant/scripts/utils.sh
write_env /etc/database.env \
    DATABASE_USER \
    DATABASE_PASSWORD \
    DATABASE_DB \
    DATABASE_PORT \
    REDIS_PORT \
    REDIS_PASSWORD \
    RABBITMQ_HOST \
    RABBITMQ_PORT \
    RABBITMQ_MANAGEMENT_PORT \
    RABBITMQ_USER \
    RABBITMQ_PASSWORD

write_env /etc/vm_hosts.env \
    HISTORY_HOST \
    FETCHER_HOST \
    FRONTEND_HOST

sudo chown root:vagrant /etc/vm_hosts.env
sudo chmod 640 /etc/vm_hosts.env

source /vagrant/scripts/docker_install.sh
install_docker

cd /vagrant/database
COMPOSE_PROFILES=()

if [[ "$QUEUE_TYPE" == "rabbitmq" ]]; then
    COMPOSE_PROFILES+=(rabbitmq)
else 
    docker compose --env-file /etc/database.env \
        rm -sf rabbitmq 2>/dev/null || true
fi

if [[ "$CACHE_TYPE" == "redis" ]]; then
    COMPOSE_PROFILES+=(redis)
else 
    docker compose --env-file /etc/database.env \
        rm -sf redis 2>/dev/null || true
fi

if ((${#COMPOSE_PROFILES[@]} > 0)); then
    PROFILE_LIST=$(IFS=,; echo "${COMPOSE_PROFILES[*]}")
    
    docker compose \
        --env-file /etc/database.env \
        --profile "$PROFILE_LIST" \
        up -d
else
    docker compose \
        --env-file /etc/database.env \
        up -d postgres
fi

wait_until_pg_isready

if [[ "$DATABASE_RESTORE" == "true" ]]; then
    restore_database
else 
    init_database
fi

if [[ "$QUEUE_TYPE" == "pgmq" ]]; then
    install_pgmq
fi

if [[ "$CACHE_TYPE" == "hstore" ]]; then
    install_hstore
fi

bash /vagrant/scripts/ssh/setup_ssh.sh database
bash /vagrant/scripts/ssh/setup_cron.sh