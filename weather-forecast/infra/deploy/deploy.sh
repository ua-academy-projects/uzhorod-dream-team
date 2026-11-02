#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

TAG=deploy
CONF_DIR=/etc/weather-forecast
DB_NAME=weather_history
BROKER_USER=weather
BROKER_VHOST=weather

command -v docker >/dev/null || die "docker is required"
[[ -r $SECRETS ]] || die "secrets not found: $SECRETS"

BACKEND=$(cfg .app.backend)
case $BACKEND in
  postgres) REQUIRED=(WEATHER_DB_PASSWORD WEATHER_FETCHER_DB_PASSWORD) ;;
  rabbitmq_redis) REQUIRED=(WEATHER_DB_PASSWORD RABBITMQ_PASSWORD REDIS_PASSWORD) ;;
  *) die "app.backend must be postgres or rabbitmq_redis" ;;
esac

secret() { sed -n "s/^$1=//p" "$SECRETS" | tail -n 1; }
host_of() { cfg --arg s "$1" '.app.hosts[$s] // error("app.hosts.\($s) is not set")'; }
image_of() { cfg --arg s "$1" '.app.images[$s] // error("app.images.\($s) is not set")'; }
sha() { sha256sum | cut -c1-16; }
image_id() { docker image inspect -f '{{.Id}}' "$1"; }

for name in "${REQUIRED[@]}"; do
  [[ $(secret "$name") =~ ^[A-Za-z0-9._~-]{16,}$ ]] ||
    die "$name must be at least 16 URL-safe characters (letters, digits, . _ ~ -)"
done
APP_PASSWORD=$(secret WEATHER_DB_PASSWORD)
FETCHER_PASSWORD=$(secret WEATHER_FETCHER_DB_PASSWORD)
RABBITMQ_PASSWORD=$(secret RABBITMQ_PASSWORD)
REDIS_PASSWORD=$(secret REDIS_PASSWORD)

DB_VM=$(host_of postgres)
RABBITMQ_VM=$(host_of rabbitmq)
REDIS_VM=$(host_of redis)
FETCHER_VM=$(host_of fetcher)
HISTORY_VM=$(host_of history)
UI_VM=$(host_of ui)
DB_IP=$(vm_attr "$DB_VM" ip)
RABBITMQ_IP=$(vm_attr "$RABBITMQ_VM" ip)
REDIS_IP=$(vm_attr "$REDIS_VM" ip)
FETCHER_IP=$(vm_attr "$FETCHER_VM" ip)
HISTORY_IP=$(vm_attr "$HISTORY_VM" ip)
RABBITMQ_IMAGE=$(image_of rabbitmq)
REDIS_IMAGE=$(image_of redis)

declare -A SOURCES=(
  [weather-postgres]=infra/postgres
  [weather-fetcher]=services/fetcher
  [weather-history]=services/history
  [weather-ui]=services/ui
)

build_images() {
  local image
  for image in "${!SOURCES[@]}"; do
    log "building $image:$TAG"
    docker build --quiet --platform linux/amd64 -t "$image:$TAG" "$ROOT/${SOURCES[$image]}" >/dev/null
  done
  if [[ $BACKEND == rabbitmq_redis ]]; then
    for image in "$RABBITMQ_IMAGE" "$REDIS_IMAGE"; do
      log "pulling $image"
      docker pull --quiet --platform linux/amd64 "$image" >/dev/null
    done
  fi
}

wait_ready() {
  log "$1: waiting for cloud-init"
  remote "$1" 'cloud-init status --wait >/dev/null; rc=$?; [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]' ||
    die "cloud-init failed on $1; see /var/log/cloud-init-output.log"
}

ship_image() {
  local vm=$1 image=$2 local_id remote_id
  local_id=$(image_id "$image")
  remote_id=$(remote "$vm" "sudo docker image inspect -f '{{.Id}}' $image 2>/dev/null" || true)
  if [[ $local_id == "$remote_id" ]]; then
    log "$vm: $image is up to date"
    return
  fi
  log "$vm: uploading $image"
  docker save "$image" | gzip -1 | remote "$vm" 'gunzip | sudo docker load >/dev/null && sudo docker image prune -f >/dev/null'
}

put_file() {
  local vm=$1 path=$2 mode=$3
  remote "$vm" "sudo install -d -m 755 $CONF_DIR && sudo sh -c 'umask 077; cat > $path.tmp && chmod $mode $path.tmp && mv -f $path.tmp $path'"
}

run_container() {
  local vm=$1 name=$2 inputs=$3 spec state
  shift 3
  spec=$(printf '%s\n' "$inputs" "$@" | sha)
  state=$(remote "$vm" "sudo docker inspect -f '{{.Config.Labels.weather_spec}} {{.State.Running}}' $name 2>/dev/null" || true)
  if [[ $state == "$spec true" ]]; then
    log "$vm: $name is unchanged"
    return
  fi
  log "$vm: starting $name"
  remote "$vm" "sudo docker stop -t 60 $name >/dev/null 2>&1; sudo docker rm -f $name >/dev/null 2>&1; sudo docker run -d --name $name --restart unless-stopped --network host --label weather_spec=$spec $(printf '%q ' "$@") >/dev/null"
}

remove_container() {
  local vm=$1 name=$2
  if remote "$vm" "sudo docker container inspect $name >/dev/null 2>&1"; then
    log "$vm: removing $name, its volume is kept"
    remote "$vm" "sudo docker stop -t 60 $name >/dev/null; sudo docker rm $name >/dev/null"
  fi
}

wait_for() {
  local vm=$1 what=$2 check=$3
  log "$vm: waiting for $what"
  remote "$vm" "for _ in \$(seq 60); do $check >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1" ||
    die "$what did not start on $vm"
}

db_psql() {
  remote "$DB_VM" "sudo docker exec -i weather-postgres psql -X -q -v ON_ERROR_STOP=1 -U postgres -d $DB_NAME $*"
}

deploy_postgres() {
  local hba
  hba=$(sed -e "s/@HISTORY_IP@/$HISTORY_IP/" -e "s/@FETCHER_IP@/$FETCHER_IP/" "$DEPLOY_DIR/templates/postgres/pg_hba.conf")
  ship_image "$DB_VM" weather-postgres:$TAG
  put_file "$DB_VM" "$CONF_DIR/pg_hba.conf" 644 <<<"$hba"
  run_container "$DB_VM" weather-postgres "$(image_id weather-postgres:$TAG) $(sha <<<"$hba")" \
    -v weather-postgres:/var/lib/postgresql \
    -v "$CONF_DIR/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro" \
    -e POSTGRES_DB=$DB_NAME \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    weather-postgres:$TAG \
    -c hba_file=/etc/postgresql/pg_hba.conf \
    -c "listen_addresses=127.0.0.1,$DB_IP"
  wait_for "$DB_VM" PostgreSQL "sudo docker exec weather-postgres pg_isready -q -h 127.0.0.1 -U postgres"

  db_psql <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgmq;
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE TABLE IF NOT EXISTS schema_migrations (
    version TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SQL

  local applied file version fetcher_login
  applied=$(db_psql -At -c "'SELECT version FROM schema_migrations'" </dev/null)
  for file in "$ROOT"/infra/postgres/migrations/*.sql; do
    version=$(basename "$file" .sql)
    grep -qxF "$version" <<<"$applied" && continue
    log "$DB_VM: applying migration $version"
    { echo 'BEGIN;'; cat "$file"; printf "\nINSERT INTO schema_migrations (version) VALUES ('%s');\nCOMMIT;\n" "$version"; } | db_psql
  done

  if [[ $BACKEND == postgres ]]; then
    fetcher_login="LOGIN PASSWORD '$FETCHER_PASSWORD'"
  else
    fetcher_login=NOLOGIN
  fi

  log "$DB_VM: configuring roles"
  db_psql <<SQL
SELECT format('CREATE ROLE %I', r) FROM unnest(ARRAY['weather_app', 'weather_fetcher']) AS r
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec
ALTER ROLE weather_app WITH LOGIN PASSWORD '$APP_PASSWORD';
ALTER ROLE weather_fetcher WITH $fetcher_login;

REVOKE ALL ON DATABASE $DB_NAME FROM PUBLIC;
GRANT CONNECT ON DATABASE $DB_NAME TO weather_app, weather_fetcher;

GRANT USAGE ON SCHEMA public, pgmq TO weather_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public, pgmq TO weather_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public, pgmq TO weather_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgmq TO weather_app;
REVOKE ALL ON schema_migrations FROM weather_app;

GRANT USAGE ON SCHEMA pgmq TO weather_fetcher;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgmq TO weather_fetcher;
GRANT SELECT ON pgmq.meta TO weather_fetcher;
GRANT SELECT, UPDATE, DELETE ON pgmq.q_weather_requests TO weather_fetcher;
GRANT INSERT ON pgmq.q_weather_responses TO weather_fetcher;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA pgmq TO weather_fetcher;
SQL
}

deploy_rabbitmq() {
  local conf env
  conf=$(cat "$DEPLOY_DIR/templates/rabbitmq/rabbitmq.conf")
  env="RABBITMQ_DEFAULT_USER=$BROKER_USER
RABBITMQ_DEFAULT_PASS=$RABBITMQ_PASSWORD
RABBITMQ_DEFAULT_VHOST=$BROKER_VHOST"
  ship_image "$RABBITMQ_VM" "$RABBITMQ_IMAGE"
  put_file "$RABBITMQ_VM" "$CONF_DIR/rabbitmq.conf" 644 <<<"$conf"
  put_file "$RABBITMQ_VM" "$CONF_DIR/weather-rabbitmq.env" 600 <<<"$env"
  run_container "$RABBITMQ_VM" weather-rabbitmq "$(image_id "$RABBITMQ_IMAGE") $(sha <<<"$conf$env")" \
    -v weather-rabbitmq:/var/lib/rabbitmq \
    -v "$CONF_DIR/rabbitmq.conf:/etc/rabbitmq/conf.d/20-weather.conf:ro" \
    --env-file "$CONF_DIR/weather-rabbitmq.env" \
    "$RABBITMQ_IMAGE"
  wait_for "$RABBITMQ_VM" RabbitMQ "sudo docker exec weather-rabbitmq rabbitmq-diagnostics -q check_running"
  remote "$RABBITMQ_VM" "sudo docker exec weather-rabbitmq sh -c 'rabbitmqctl -q change_password \"\$RABBITMQ_DEFAULT_USER\" \"\$RABBITMQ_DEFAULT_PASS\"'"
}

deploy_redis() {
  local conf uid
  conf="bind 127.0.0.1 $REDIS_IP
appendonly yes
requirepass $REDIS_PASSWORD"
  ship_image "$REDIS_VM" "$REDIS_IMAGE"
  uid=$(remote "$REDIS_VM" "sudo docker run --rm --entrypoint id $REDIS_IMAGE -u redis")
  put_file "$REDIS_VM" "$CONF_DIR/redis.conf" 600 <<<"$conf"
  remote "$REDIS_VM" "sudo chown $uid $CONF_DIR/redis.conf"
  run_container "$REDIS_VM" weather-redis "$(image_id "$REDIS_IMAGE") $(sha <<<"$conf")" \
    -v weather-redis:/data \
    -v "$CONF_DIR/redis.conf:/usr/local/etc/redis/redis.conf:ro" \
    "$REDIS_IMAGE" \
    redis-server /usr/local/etc/redis/redis.conf
}

deploy_service() {
  local vm=$1 name=$2 env=$3
  shift 3
  ship_image "$vm" "$name:$TAG"
  put_file "$vm" "$CONF_DIR/$name.env" 600 <<<"$env"
  run_container "$vm" "$name" "$(image_id "$name:$TAG") $(sha <<<"$env")" \
    --env-file "$CONF_DIR/$name.env" "$@" "$name:$TAG"
}

deploy_ui() {
  local nginx
  nginx=$(sed "s/@HISTORY_IP@/$HISTORY_IP/" "$DEPLOY_DIR/templates/nginx/default.conf")
  ship_image "$UI_VM" weather-ui:$TAG
  put_file "$UI_VM" "$CONF_DIR/nginx.conf" 644 <<<"$nginx"
  run_container "$UI_VM" weather-ui "$(image_id weather-ui:$TAG) $(sha <<<"$nginx")" \
    -v "$CONF_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
    weather-ui:$TAG
}

build_images

for vm in $(printf '%s\n' "$DB_VM" "$RABBITMQ_VM" "$REDIS_VM" "$FETCHER_VM" "$HISTORY_VM" "$UI_VM" | sort -u); do
  wait_ready "$vm"
done

deploy_postgres

DATABASE_URL="postgresql://weather_app:$APP_PASSWORD@$DB_IP:5432/$DB_NAME"
if [[ $BACKEND == rabbitmq_redis ]]; then
  deploy_rabbitmq
  deploy_redis
  BROKER_URL="amqp://$BROKER_USER:$RABBITMQ_PASSWORD@$RABBITMQ_IP:5672/$BROKER_VHOST"
  FETCHER_ENV="WEATHER_BACKEND=rabbitmq_redis
RABBITMQ_URL=$BROKER_URL
FETCHER_HOST=127.0.0.1"
  HISTORY_QUEUE_ENV="RABBITMQ_URL=$BROKER_URL
REDIS_ADDR=$REDIS_IP:6379
REDIS_PASSWORD=$REDIS_PASSWORD"
else
  remove_container "$RABBITMQ_VM" weather-rabbitmq
  remove_container "$REDIS_VM" weather-redis
  FETCHER_ENV="WEATHER_BACKEND=postgres
DATABASE_URL=postgresql://weather_fetcher:$FETCHER_PASSWORD@$DB_IP:5432/$DB_NAME
FETCHER_HOST=127.0.0.1"
  HISTORY_QUEUE_ENV=""
fi

deploy_service "$FETCHER_VM" weather-fetcher "$FETCHER_ENV"

deploy_service "$HISTORY_VM" weather-history "WEATHER_BACKEND=$BACKEND
DATABASE_URL=$DATABASE_URL
HISTORY_ADDR=$HISTORY_IP:8002
HISTORY_SERVE_UI=false
SESSION_COOKIE_SECURE=$(cfg .app.session_cookie_secure)
$HISTORY_QUEUE_ENV"

deploy_ui

log "done"
