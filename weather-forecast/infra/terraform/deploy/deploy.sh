#!/usr/bin/env bash
set -euo pipefail
umask 077

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tf=$(dirname "$here")
root=$(cd "$tf/../.." && pwd)
secrets=${WEATHER_SECRETS:-$root/var/deploy/secrets.env}
key=${WEATHER_SSH_KEY:-$HOME/.ssh/weather_vm}
config=/etc/weather-forecast
state=/var/lib/weather-forecast

db_ip=192.168.56.11
fetcher_ip=192.168.56.12
history_ip=192.168.56.13
ui_ip=192.168.56.14

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
dk() { ${DOCKER:-docker} "$@"; }

decode_url_part() {
  local value=$1 remaining
  remaining=$(printf '%s' "$value" | sed -E 's/%[0-9a-fA-F]{2}//g')
  [[ "$remaining" != *%* && "$value" != *'\'* && ! "$value" =~ %(0[0-9a-fA-F]|1[0-9a-fA-F]|7[fF]) ]] || {
    echo 'Invalid URL encoding or control character in RABBITMQ_URL' >&2; return 1;
  }
  printf '%b' "${value//%/\\x}"
}

read_broker_settings() {
  local pattern='^amqp://([^:/@]+):([^/@]+)@([^/:]+)(:([0-9]+))?(/([^?#]*))?$'
  [[ "$RABBITMQ_URL" != *'?'* && "$RABBITMQ_URL" != *'#'* && "$RABBITMQ_URL" =~ $pattern ]] || {
    echo 'Use amqp://USER:PASSWORD@DB_IP:5672/VHOST with URL-encoded credentials' >&2; return 1;
  }
  local username=${BASH_REMATCH[1]} password=${BASH_REMATCH[2]} address=${BASH_REMATCH[3]}
  local port=${BASH_REMATCH[5]} path=${BASH_REMATCH[6]} vhost=${BASH_REMATCH[7]}
  [[ "$address" == "$db_ip" && ( -z "$port" || "$port" == 5672 ) ]] || {
    echo 'RABBITMQ_URL must point to the DB VM on port 5672' >&2; return 1;
  }
  rabbit_user=$(decode_url_part "$username") || return 1
  rabbit_password=$(decode_url_part "$password") || return 1
  rabbit_vhost=/
  if [[ -n "$path" ]]; then rabbit_vhost=$(decode_url_part "$vhost") || return 1; fi
  [[ -n "$rabbit_user" && "$rabbit_user" != guest && "$rabbit_user" != -* && -n "$rabbit_password" && -n "$rabbit_vhost" && "$rabbit_vhost" != -* ]] || {
    echo 'Use a non-guest RabbitMQ user, a password and a nonempty vhost' >&2; return 1;
  }
  [[ ${REDIS_ADDR:-$db_ip:6379} == "$db_ip:6379" ]] || {
    echo 'REDIS_ADDR must point to the DB VM on port 6379' >&2; return 1;
  }
}

load_secrets() {
  [[ -f "$secrets" ]] || die "missing $secrets"
  source "$secrets"
  WEATHER_BACKEND=${WEATHER_BACKEND:-rabbitmq_redis}
  [[ "$WEATHER_BACKEND" == rabbitmq_redis || "$WEATHER_BACKEND" == postgres ]] ||
    die 'WEATHER_BACKEND must be rabbitmq_redis or postgres'
  [[ ${WEATHER_DB_PASSWORD:-} =~ ^[a-f0-9]{48}$ ]] ||
    die 'WEATHER_DB_PASSWORD must contain 48 hexadecimal characters'
  if [[ "$WEATHER_BACKEND" == postgres ]]; then
    [[ ${WEATHER_FETCHER_DB_PASSWORD:-} =~ ^[a-f0-9]{48}$ ]] ||
      die 'WEATHER_FETCHER_DB_PASSWORD must contain 48 hexadecimal characters'
  else
    [[ ${RABBITMQ_URL:-} == amqp://* ]] || die 'Set RABBITMQ_URL in secrets.env'
    [[ "$RABBITMQ_URL" != *$'\n'* && "$RABBITMQ_URL" != *'"'* && "$RABBITMQ_URL" != *'\'* ]] ||
      die 'URL-encode special characters in RABBITMQ_URL'
    [[ -n ${REDIS_PASSWORD:-} && ! "$REDIS_PASSWORD" =~ [[:cntrl:]] ]] ||
      die 'Set a single-line REDIS_PASSWORD in secrets.env'
    read_broker_settings || exit 1
  fi
}

tfout() { terraform -chdir="$tf" output -raw "$1"; }

setup_ssh() {
  bastion=$(tfout bastion_external_ip)
  port=$(tfout ssh_port)
  user=$(tfout ssh_user)
  opts=(-i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o ServerAliveInterval=30
        -o UserKnownHostsFile="$tf/.known_hosts" -o StrictHostKeyChecking=accept-new)
  proxy="ssh ${opts[*]} -p $port -W %h:%p jump@$bastion"
}

bastion_ssh() { ssh "${opts[@]}" -p "$port" "$user@$bastion" "$@"; }

vm() {
  local ip=$1
  shift
  ssh "${opts[@]}" -p "$port" -o ProxyCommand="$proxy" "$user@$ip" "$@"
}

put() {
  vm "$1" "sudo sh -c 'umask 077; cat > $2.new; chmod $3 $2.new; mv -f $2.new $2'"
}

wait_ready() {
  local label=$1 attempt=0
  shift
  until "$@" 'test -f /var/lib/weather-forecast/bootstrap-done' 2>/dev/null; do
    attempt=$((attempt + 1))
    [[ $attempt -le 60 ]] || die "$label bootstrap is not finished"
    sleep 10
  done
}

render() {
  sed -e "s|@DB_IP@|$db_ip|g" \
      -e "s|@HISTORY_IP@|$history_ip|g" \
      -e "s|@FETCHER_IP@|$fetcher_ip|g" "$1"
}

build_images() {
  log 'building images on the host'
  dk build -f "$root/infra/postgres/Dockerfile" -t weather-postgres:dev "$root/infra/postgres"
  local service
  for service in fetcher history ui; do
    dk build -f "$root/services/$service/Dockerfile" -t "weather-$service:dev" "$root/services/$service"
  done
  if [[ "$WEATHER_BACKEND" == rabbitmq_redis ]]; then
    dk pull rabbitmq:4.3-alpine
    dk pull redis:7.4-alpine
  fi
}

load_image() {
  local ip=$1 image=$2 local_id remote_id
  local_id=$(dk image inspect --format '{{.Id}}' "$image")
  remote_id=$(vm "$ip" "sudo docker image inspect --format '{{.Id}}' $image 2>/dev/null" || true)
  if [[ "$local_id" == "$remote_id" ]]; then
    log "$image is already on $ip"
    return 0
  fi
  log "copying $image to $ip"
  dk save "$image" | gzip | vm "$ip" 'gunzip | sudo docker load'
}

remove_remote() {
  vm "$1" "if sudo docker container inspect $2 >/dev/null 2>&1; then sudo docker stop --time 60 $2 >/dev/null; sudo docker rm $2 >/dev/null; fi"
}

deploy_db() {
  log "db $db_ip"
  {
    printf 'WEATHER_DB_PASSWORD=%s\n' "$WEATHER_DB_PASSWORD"
    [[ "$WEATHER_BACKEND" != postgres ]] || printf 'WEATHER_FETCHER_DB_PASSWORD=%s\n' "$WEATHER_FETCHER_DB_PASSWORD"
  } | put "$db_ip" "$config/db-app.env" 600
  render "$tf/templates/postgres/pg_hba.conf" | put "$db_ip" "$config/postgres-hba.conf" 644
  if [[ "$WEATHER_BACKEND" == rabbitmq_redis ]]; then
    printf 'RABBITMQ_DEFAULT_USER=%s\nRABBITMQ_DEFAULT_PASS=%s\nRABBITMQ_DEFAULT_VHOST=%s\n' \
      "$rabbit_user" "$rabbit_password" "$rabbit_vhost" | put "$db_ip" "$config/rabbitmq.env" 600
    printf 'REDIS_PASSWORD=%s\n' "$REDIS_PASSWORD" | put "$db_ip" "$config/redis.env" 600
    put "$db_ip" "$config/rabbitmq.conf" 644 < "$tf/templates/rabbitmq/rabbitmq.conf"
  fi
  tar -C "$root/infra/postgres" -cf - migrations |
    vm "$db_ip" "sudo rm -rf $state/migrations; sudo tar -C $state -xf -"
  put "$db_ip" "$state/remote-db.sh" 700 < "$here/remote-db.sh"
  vm "$db_ip" "sudo bash $state/remote-db.sh $WEATHER_BACKEND $db_ip"
}

deploy_fetcher() {
  log "fetcher $fetcher_ip"
  {
    printf 'WEATHER_BACKEND=%s\n' "$WEATHER_BACKEND"
    if [[ "$WEATHER_BACKEND" == postgres ]]; then
      printf 'DATABASE_URL=postgres://weather_fetcher:%s@%s:5432/weather_history?sslmode=disable\n' \
        "$WEATHER_FETCHER_DB_PASSWORD" "$db_ip"
    else
      printf 'RABBITMQ_URL=%s\n' "$RABBITMQ_URL"
    fi
  } | put "$fetcher_ip" "$config/fetcher.env" 600
  remove_remote "$fetcher_ip" weather-fetcher
  vm "$fetcher_ip" "sudo docker run --detach --name weather-fetcher --restart unless-stopped \
    --log-driver local --log-opt max-size=10m --log-opt max-file=3 \
    --env-file $config/fetcher.env weather-fetcher:dev"
}

deploy_history() {
  log "history $history_ip"
  {
    cat <<EOF
WEATHER_BACKEND=$WEATHER_BACKEND
DATABASE_URL=postgres://weather_app:$WEATHER_DB_PASSWORD@$db_ip:5432/weather_history?sslmode=disable
COLLECT_INTERVAL=15m
TEMPERATURE_SYNC_INTERVAL=1h
TEMPERATURE_HISTORY_DAYS=30
HISTORY_ADDR=0.0.0.0:8002
HISTORY_SERVE_UI=false
SESSION_COOKIE_SECURE=${SESSION_COOKIE_SECURE:-false}
JOB_TIMEOUT=120s
CITY_NAME=${CITY_NAME:-Uzhhorod}
CITY_LATITUDE=${CITY_LATITUDE:-48.6167}
CITY_LONGITUDE=${CITY_LONGITUDE:-22.3}
EOF
    if [[ "$WEATHER_BACKEND" == rabbitmq_redis ]]; then
      printf 'RABBITMQ_URL=%s\nREDIS_ADDR=%s\nREDIS_PASSWORD=%s\n' \
        "$RABBITMQ_URL" "${REDIS_ADDR:-$db_ip:6379}" "$REDIS_PASSWORD"
    fi
  } | put "$history_ip" "$config/history.env" 600
  remove_remote "$history_ip" weather-history
  vm "$history_ip" "sudo docker run --detach --name weather-history --restart unless-stopped \
    --log-driver local --log-opt max-size=10m --log-opt max-file=3 \
    --env-file $config/history.env --publish $history_ip:8002:8002 weather-history:dev"
}

deploy_ui() {
  log "ui $ui_ip"
  render "$tf/templates/nginx/default.conf" | put "$ui_ip" "$config/nginx.conf" 644
  vm "$ui_ip" "sudo docker run --rm \
    --mount type=bind,src=$config/nginx.conf,dst=/etc/nginx/conf.d/default.conf,readonly \
    weather-ui:dev nginx -t"
  remove_remote "$ui_ip" weather-ui
  vm "$ui_ip" "sudo docker run --detach --name weather-ui --restart unless-stopped \
    --log-driver local --log-opt max-size=10m --log-opt max-file=3 \
    --publish 80:80 \
    --mount type=bind,src=$config/nginx.conf,dst=/etc/nginx/conf.d/default.conf,readonly \
    weather-ui:dev"
}

install_cloudflared() {
  if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
    log 'CLOUDFLARE_TUNNEL_TOKEN is not set, skipping cloudflared'
    return 0
  fi
  log 'cloudflared on bastion'
  bastion_ssh 'command -v cloudflared >/dev/null || {
    sudo mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y cloudflared
  }'
  printf '%s' "$CLOUDFLARE_TUNNEL_TOKEN" |
    bastion_ssh 'if sudo systemctl is-active --quiet cloudflared; then echo "cloudflared is already running"; else read -r token; sudo cloudflared service install "$token"; fi'
}

report() {
  local entry
  for entry in "db:$db_ip" "fetcher:$fetcher_ip" "history:$history_ip" "ui:$ui_ip"; do
    log "${entry%%:*}"
    vm "${entry#*:}" "sudo docker ps --format '{{.Names}}  {{.Status}}'"
  done
}

main() {
  load_secrets
  setup_ssh

  log "backend: $WEATHER_BACKEND"
  log 'waiting for VM bootstrap'
  wait_ready bastion bastion_ssh
  local ip
  for ip in "$db_ip" "$fetcher_ip" "$history_ip" "$ui_ip"; do
    wait_ready "$ip" vm "$ip"
  done

  build_images
  load_image "$db_ip" weather-postgres:dev
  if [[ "$WEATHER_BACKEND" == rabbitmq_redis ]]; then
    load_image "$db_ip" rabbitmq:4.3-alpine
    load_image "$db_ip" redis:7.4-alpine
  fi
  load_image "$fetcher_ip" weather-fetcher:dev
  load_image "$history_ip" weather-history:dev
  load_image "$ui_ip" weather-ui:dev

  deploy_db
  deploy_fetcher
  deploy_history
  deploy_ui
  install_cloudflared
  report
}

main "$@"
