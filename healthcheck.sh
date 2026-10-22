#!/usr/bin/env bash
# Health check for the three VMs (weather-vm, fetcher-vm, history-vm).
# Run from WSL in the project folder:
#   ./healthcheck.sh
# Prints only check names and OK/FAIL (no API responses).
# Common checks run always; the others depend on app_mode in weather-vm.yml:
#   rabbitmq - History and Fetcher use the RabbitMQ queues, settings are in Redis;
#   postgres - they use the pgmq queues, settings are in PostgreSQL (hstore, pg_cron).
# Exit code is 1 if any check failed.
set -u
cd "$(dirname "$0")" || exit 1

DB_IP="10.10.10.10"
APP_MODE=$(sed -n 's/^app_mode: *\([a-z]*\).*/\1/p' weather-vm.yml)
SITE="http://127.0.0.1:8081"

failed=0

# Runs a check command without showing its output and prints OK or FAIL.
check() {
  local name="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    echo "$name: OK"
  else
    echo "$name: FAIL"
    failed=1
  fi
}

# Is the systemd service active in the VM? Usage: service_active VM SERVICE
service_active() {
  vagrant ssh "$1" -c "systemctl is-active --quiet $2"
}

# Is the Docker container running in the VM? Usage: container_running VM CONTAINER
container_running() {
  vagrant ssh "$1" -c "sudo docker inspect --format '{{.State.Running}}' $2" | grep -q '^true'
}

# Is the systemd service NOT running? Usage: service_inactive VM SERVICE
service_inactive() {
  # "!" runs inside the VM: if the VM is not reachable, the check fails, not passes.
  vagrant ssh "$1" -c "! systemctl is-active --quiet $2"
}

# Is the TCP port closed for the VM (blocked by the firewall)? Usage: port_closed VM IP PORT
# "!" runs inside the VM: if the VM is not reachable, the check fails, not passes.
port_closed() {
  vagrant ssh "$1" -c "! timeout 5 bash -c 'echo > /dev/tcp/$2/$3'"
}

# Does the RabbitMQ queue have exactly COUNT consumers (services that read it)?
# 1 in mode rabbitmq (no duplicates), 0 in mode postgres (nobody reads the old queue).
# rabbitmqctl runs inside the RabbitMQ container. Usage: queue_consumers QUEUE COUNT
queue_consumers() {
  vagrant ssh weather-vm -c "sudo docker exec weather-rabbitmq rabbitmqctl --silent list_queues -p weather name consumers" |
    awk -v queue="$1" -v count="$2" '{ sub(/\r$/, "") } $1 == queue && $2 == count { found = 1 } END { exit !found }'
}

# Is the answer of an SQL query in the database of the app "t" (true)? Usage: sql_true QUERY
sql_true() {
  vagrant ssh weather-vm -c "sudo -u postgres psql -d weather_history -tAc \"$1\"" | tr -d '\r' | grep -qx t
}

# The settings are saved and read back (Redis or PostgreSQL, by the mode).
# PUT without a cookie makes a new session; GET with its cookie must return the same settings.
# It leaves one test session, which expires after 30 days like any other.
settings_round_trip() {
  local cookie
  cookie=$(curl.exe --fail --silent --max-time 20 --request PUT \
      --header "Content-Type: application/json" --data '{"theme":"dark","lang":"en"}' \
      --dump-header - --output NUL "$SITE/api/settings" |
    tr -d '\r' | sed -n 's/^[Ss]et-[Cc]ookie: \(wh_session=[A-Z2-7]*\).*/\1/p')
  [[ -n "$cookie" ]] || return 1
  curl.exe --fail --silent --max-time 20 --header "Cookie: $cookie" "$SITE/api/settings" |
    python3 -c 'import json, sys; sys.exit(json.load(sys.stdin) != {"theme": "dark", "lang": "en"})'
}

# The whole path works: History -> queue -> Fetcher -> queue -> History -> PostgreSQL -> API.
# The newest record must be fresh. Open-Meteo updates the measurement every 15 minutes,
# and a duplicate is not saved, so "fresh" here means younger than 30 minutes.
fresh_record() {
  curl.exe --fail --silent --max-time 20 "$SITE/api/history" |
    python3 -c '
import json, sys
from datetime import datetime, timedelta, timezone
records = json.load(sys.stdin)
newest = datetime.fromisoformat(records[0]["fetched_at"].replace("Z", "+00:00"))
sys.exit(0 if datetime.now(timezone.utc) - newest < timedelta(minutes=30) else 1)
'
}

# Can the VM open a TCP connection to the port? Usage: port_open VM IP PORT
port_open() {
  vagrant ssh "$1" -c "timeout 5 bash -c 'echo > /dev/tcp/$2/$3'"
}

# The site is forwarded to Windows 127.0.0.1:8081. WSL cannot reach that address,
# so Windows curl.exe checks it, the same way the browser sees it.
site_responds() {
  curl.exe --fail --silent --max-time 20 --output NUL "$SITE$1"
}

if [[ "$APP_MODE" != "rabbitmq" && "$APP_MODE" != "postgres" ]]; then
  echo "app_mode not found in weather-vm.yml" >&2
  exit 1
fi
echo "Mode: $APP_MODE"

# --- Common checks (both modes) ---
check "weather-vm: PostgreSQL" service_active weather-vm postgresql
# RabbitMQ and Redis keep running in mode postgres too (only not used), so a switch back is fast.
check "weather-vm: RabbitMQ container" container_running weather-vm weather-rabbitmq
# The old RabbitMQ (Ubuntu package, before Docker) must not run at the same time.
check "weather-vm: old systemd RabbitMQ stopped" service_inactive weather-vm rabbitmq-server
check "weather-vm: Redis container" container_running weather-vm weather-redis
# The old Redis (Ubuntu package, before Docker) must not run at the same time.
check "weather-vm: old systemd Redis stopped" service_inactive weather-vm redis-server
check "fetcher-vm: Fetcher container" container_running fetcher-vm weather-fetcher
# The old Fetcher (systemd, before Docker) must not read the same queue at the same time.
check "fetcher-vm: old systemd Fetcher stopped" service_inactive fetcher-vm weather-fetcher
check "history-vm: History container" container_running history-vm weather-history
# The old History (systemd, before Docker) must not run at the same time.
check "history-vm: old systemd History stopped" service_inactive history-vm weather-history
check "history-vm -> PostgreSQL :5432" port_open history-vm "$DB_IP" 5432
# Redis is only for History: the firewall must block it for other VMs.
check "fetcher-vm -> Redis :6379 blocked" port_closed fetcher-vm "$DB_IP" 6379
# The extensions are installed in both modes (provision/db-extensions.sh).
check "PostgreSQL extensions pgmq, pg_cron, hstore" \
  sql_true "SELECT count(*) = 3 FROM pg_extension WHERE extname IN ('pgmq', 'pg_cron', 'hstore')"
check "History /api/history" site_responds /api/history
check "UI /" site_responds /

if [[ "$APP_MODE" == "rabbitmq" ]]; then
  # --- Mode rabbitmq: RabbitMQ queues, settings in Redis ---
  check "history-vm -> RabbitMQ :5672" port_open history-vm "$DB_IP" 5672
  check "fetcher-vm -> RabbitMQ :5672" port_open fetcher-vm "$DB_IP" 5672
  check "history-vm -> Redis :6379" port_open history-vm "$DB_IP" 6379
  check "Fetcher reads weather.requests (1 consumer)" queue_consumers weather.requests 1
  check "History reads weather.responses (1 consumer)" queue_consumers weather.responses 1
  # Fetcher must not log in to PostgreSQL in this mode (provision/db-mode.sh).
  check "PostgreSQL role weather_fetcher cannot log in" \
    sql_true "SELECT NOT rolcanlogin FROM pg_roles WHERE rolname = 'weather_fetcher'"
  check "Settings saved and read back (Redis)" settings_round_trip
else
  # --- Mode postgres: pgmq queues, settings in PostgreSQL (hstore + pg_cron) ---
  check "fetcher-vm -> PostgreSQL :5432" port_open fetcher-vm "$DB_IP" 5432
  check "PostgreSQL role weather_fetcher can log in" \
    sql_true "SELECT rolcanlogin FROM pg_roles WHERE rolname = 'weather_fetcher'"
  check "pgmq queues weather_requests, weather_responses" \
    sql_true "SELECT count(*) = 2 FROM pgmq.list_queues() WHERE queue_name IN ('weather_requests', 'weather_responses')"
  # Somebody reads the queues: no message waits longer than a request lives (5 minutes).
  check "pgmq queues are read (no message older than 5 min)" \
    sql_true "SELECT coalesce(max(oldest_msg_age_sec), 0) < 300 FROM pgmq.metrics_all() WHERE queue_name IN ('weather_requests', 'weather_responses')"
  # Nobody reads the old RabbitMQ queues: the old mode is really off.
  check "Nobody reads weather.requests in RabbitMQ (0 consumers)" queue_consumers weather.requests 0
  check "Nobody reads weather.responses in RabbitMQ (0 consumers)" queue_consumers weather.responses 0
  check "user_settings.settings is hstore" \
    sql_true "SELECT atttypid = 'hstore'::regtype FROM pg_attribute WHERE attrelid = 'user_settings'::regclass AND attname = 'settings'"
  # The job is active, and its last run (if it has run already) succeeded.
  check "pg_cron job weather-expired-settings (active, last run OK)" \
    sql_true "SELECT bool_and(j.active) AND coalesce((SELECT d.status = 'succeeded' FROM cron.job_run_details d WHERE d.jobid = min(j.jobid) ORDER BY d.start_time DESC LIMIT 1), true) FROM cron.job j WHERE j.jobname = 'weather-expired-settings'"
  check "Settings saved and read back (PostgreSQL hstore)" settings_round_trip
fi

check "Fresh record (< 30 min)" fresh_record

exit "$failed"
