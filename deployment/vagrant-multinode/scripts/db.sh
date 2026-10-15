#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed 's/\r$//' /tmp/kyiv-air-common.sh)

read_database
if [[ "$POSTGRES_ONLY" == true ]]; then
  read_queue
  [[ "$QUEUE_DB_NAME" == "$DB_NAME" ]] || fail "POSTGRES_DB must match in db.env and queue.env."
else
  read_rabbitmq
fi
install_docker
configure_firewall
ensure_network

copy_env db
set_env db POSTGRES_USER kyiv_air
set_env db POSTGRES_PASSWORD "$DB_PASSWORD"
sed -i '/^REDIS_PASSWORD=/d' "$CONFIG/db.env"
pg_ports=(-p "$PRIVATE_IP:5432:5432" -p 127.0.0.1:5432:5432)
docker pull "$POSTGRES_IMAGE"
docker volume create kyiv-air-postgres-data >/dev/null
replace_container kyiv-air-postgres "${pg_ports[@]}" --env-file "$CONFIG/db.env" \
  -v kyiv-air-postgres-data:/var/lib/postgresql/data "$POSTGRES_IMAGE"
wait_command PostgreSQL docker exec kyiv-air-postgres pg_isready -h 127.0.0.1 -U kyiv_air -d "$DB_NAME"
wait_command "PostgreSQL database" docker exec kyiv-air-postgres psql -U kyiv_air -d "$DB_NAME" -v ON_ERROR_STOP=1 -c 'SELECT 1'
docker exec -i kyiv-air-postgres psql -U kyiv_air -d "$DB_NAME" -v ON_ERROR_STOP=1 < <(
  printf "\\set password '%s'\n" "$DB_PASSWORD"
  printf "ALTER ROLE kyiv_air WITH PASSWORD :'password';\n"
) >/dev/null

build_image history "$MIGRATION_IMAGE" --target migrate
printf 'GOOSE_DBSTRING=postgres://kyiv_air:%s@kyiv-air-postgres:5432/%s?sslmode=disable\n' "$DB_PASSWORD" "$DB_NAME" > "$CONFIG/migrate.env"
chmod 0600 "$CONFIG/migrate.env"
require_ca_bundle
docker run --rm --name kyiv-air-migrate --network "$NETWORK" --env-file "$CONFIG/migrate.env" \
  --mount type=bind,src=/etc/ssl/certs/ca-certificates.crt,dst=/etc/ssl/certs/ca-certificates.crt,readonly \
  -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt "$MIGRATION_IMAGE" up

if [[ "$POSTGRES_ONLY" == true ]]; then
  docker exec -i kyiv-air-postgres psql -U kyiv_air -d "$DB_NAME" -v ON_ERROR_STOP=1 < <(
    printf "\\set password '%s'\n" "$FETCHER_DB_PASSWORD"
    cat <<'SQL'
SELECT 'CREATE ROLE kyiv_air_fetcher LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='kyiv_air_fetcher')
\gexec
ALTER ROLE kyiv_air_fetcher WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD :'password';
GRANT USAGE ON SCHEMA sync_queue TO kyiv_air_fetcher;
GRANT SELECT, UPDATE ON sync_queue.requests TO kyiv_air_fetcher;
SQL
  ) >/dev/null
  for container in kyiv-air-redis kyiv-air-rabbitmq; do
    if docker container inspect "$container" >/dev/null 2>&1; then
      docker stop --timeout 30 "$container" >/dev/null
      docker rm "$container" >/dev/null
    fi
  done
  rm -f "$CONFIG/redis.conf" "$CONFIG/redis-probe.env" "$CONFIG/rabbitmq.conf" "$CONFIG/rabbitmq.env"
  exit 0
fi

printf 'REDISCLI_AUTH=%s\n' "$REDIS_PASSWORD" > "$CONFIG/redis-probe.env"
chmod 0600 "$CONFIG/redis-probe.env"
cat > "$CONFIG/redis.conf" <<REDIS
bind 0.0.0.0
protected-mode yes
requirepass $REDIS_PASSWORD
dir /data
appendonly yes
appendfsync everysec
save ""
maxmemory 128mb
maxmemory-policy allkeys-lru
REDIS
chmod 0644 "$CONFIG/redis.conf"

cat > "$CONFIG/rabbitmq.env" <<RABBIT
RABBITMQ_DEFAULT_USER=kyiv_air
RABBITMQ_DEFAULT_PASS=$RABBITMQ_PASSWORD
RABBITMQ_DEFAULT_VHOST=kyiv-air
RABBITMQ_NODENAME=rabbit@kyiv-air-rabbitmq
RABBIT
chmod 0600 "$CONFIG/rabbitmq.env"
printf 'vm_memory_high_watermark.absolute = 512MB\n' > "$CONFIG/rabbitmq.conf"
chmod 0644 "$CONFIG/rabbitmq.conf"

redis_ports=(-p "$PRIVATE_IP:6379:6379" -p 127.0.0.1:6379:6379)
rabbit_ports=(-p "$PRIVATE_IP:5672:5672" -p 127.0.0.1:5672:5672)
docker pull "$REDIS_IMAGE"
docker pull "$RABBITMQ_IMAGE"
for component in redis rabbitmq; do docker volume create "kyiv-air-$component-data" >/dev/null; done
replace_container kyiv-air-redis "${redis_ports[@]}" \
  -v kyiv-air-redis-data:/data -v "$CONFIG/redis.conf:/usr/local/etc/redis/redis.conf:ro" \
  "$REDIS_IMAGE" redis-server /usr/local/etc/redis/redis.conf
wait_command Redis docker run --rm --network "$NETWORK" --env-file "$CONFIG/redis-probe.env" \
  "$REDIS_IMAGE" sh -c '[ "$(redis-cli -h kyiv-air-redis PING)" = PONG ]'
replace_container kyiv-air-rabbitmq "${rabbit_ports[@]}" -p 127.0.0.1:15672:15672 \
  --hostname kyiv-air-rabbitmq --env-file "$CONFIG/rabbitmq.env" \
  -v kyiv-air-rabbitmq-data:/var/lib/rabbitmq -v "$CONFIG/rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro" "$RABBITMQ_IMAGE"
wait_command RabbitMQ docker exec kyiv-air-rabbitmq rabbitmq-diagnostics -q check_running
docker exec kyiv-air-rabbitmq sh -c 'rabbitmqctl -q change_password kyiv_air "$RABBITMQ_DEFAULT_PASS" >/dev/null 2>&1' || fail "Could not update RabbitMQ credentials."
docker exec kyiv-air-rabbitmq rabbitmqctl -q set_permissions -p kyiv-air kyiv_air '.*' '.*' '.*'
docker exec kyiv-air-rabbitmq rabbitmqctl -q set_user_tags kyiv_air management
docker exec kyiv-air-rabbitmq sh -c 'rabbitmqctl -q authenticate_user kyiv_air "$RABBITMQ_DEFAULT_PASS" >/dev/null 2>&1' || fail "RabbitMQ authentication failed."
wait_command AMQP docker exec kyiv-air-rabbitmq rabbitmq-diagnostics -q check_port_listener 5672
