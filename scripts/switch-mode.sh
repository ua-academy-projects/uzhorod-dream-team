#!/usr/bin/env bash
# Switches the mode of the app (app_mode in weather-vm.yml):
#   rabbitmq - queues in RabbitMQ, settings in Redis;
#   postgres - queues of pgmq and settings (hstore + pg_cron) in PostgreSQL.
# Run from WSL (from any folder), with all three VMs running:
#   ./scripts/switch-mode.sh postgres
#   ./scripts/switch-mode.sh rabbitmq
# Steps:
#   1. History stops making new requests (signal USR1), answers and HTTP keep working;
#   2. the script waits until both queues of the OLD mode are empty, so no request
#      or answer is lost (at most WAIT_SECONDS; if they are not empty, History makes
#      requests again and nothing is changed);
#   3. app_mode in weather-vm.yml is changed;
#   4. only the steps that depend on the mode are provisioned again: db-mode and db-firewall
#      (weather-vm), fetcher (fetcher-vm), history (history-vm). The images are not built again;
#   5. ./healthcheck.sh checks the result.
# If the mode in weather-vm.yml is already the one asked for, steps 1-3 are skipped and
# step 4 is done again: this finishes a switch that stopped half way.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

# A request lives 5 minutes, a lease of Fetcher 1 minute: 10 minutes are enough for the queue
# to be emptied, or for an old request to expire.
WAIT_SECONDS=600
CHECK_EVERY_SECONDS=10

new_mode="${1:-}"
if [[ "$new_mode" != "rabbitmq" && "$new_mode" != "postgres" ]]; then
  echo "Usage: $0 rabbitmq|postgres" >&2
  exit 1
fi

old_mode=$(sed -n 's/^app_mode: *\([a-z]*\).*/\1/p' weather-vm.yml)
if [[ "$old_mode" != "rabbitmq" && "$old_mode" != "postgres" ]]; then
  echo "app_mode not found in weather-vm.yml" >&2
  exit 1
fi

# All three VMs must run: the switch touches each of them.
for vm in weather-vm fetcher-vm history-vm; do
  state=$(vagrant status "$vm" --machine-readable | awk -F, '$3 == "state" { print $4 }')
  if [[ "$state" != "running" ]]; then
    echo "$vm is $state, not running. Start it first: vagrant up $vm" >&2
    exit 1
  fi
done

# Number of messages (waiting and taken, not yet confirmed) in both queues of a mode.
queue_messages() {
  if [[ "$1" == "rabbitmq" ]]; then
    vagrant ssh weather-vm -c "sudo docker exec weather-rabbitmq \
      rabbitmqctl --silent list_queues -p weather name messages" |
      awk '$1 == "weather.requests" || $1 == "weather.responses" { sum += $2 } END { print sum + 0 }'
  else
    vagrant ssh weather-vm -c "sudo -u postgres psql -d weather_history -tAc \
      \"SELECT coalesce(sum(queue_length), 0) FROM pgmq.metrics_all() \
        WHERE queue_name IN ('weather_requests', 'weather_responses')\""
  fi
}

if [[ "$old_mode" == "$new_mode" ]]; then
  echo "app_mode is already $new_mode: the steps of the mode are applied again"
else
  echo "Switching $old_mode -> $new_mode"

  # 1. No new requests. Answers to the requests already sent are still handled.
  vagrant ssh history-vm -c "sudo docker kill --signal USR1 weather-history" >/dev/null
  echo "History makes no new requests"

  # 2. Wait until the old queues are empty.
  waited=0
  while true; do
    count=$(queue_messages "$old_mode" | tr -d '[:space:]\r')
    if [[ "$count" == "0" ]]; then
      echo "Queues of $old_mode are empty"
      break
    fi
    if (( waited >= WAIT_SECONDS )); then
      # Nothing was changed: History is restarted and makes requests again.
      vagrant ssh history-vm -c "sudo docker restart weather-history" >/dev/null
      echo "Queues of $old_mode still have ${count:-?} messages after ${WAIT_SECONDS} s." >&2
      echo "Nothing was changed, History makes requests again. Check Fetcher (docker logs)." >&2
      exit 1
    fi
    echo "Queues of $old_mode: ${count:-?} messages, waiting..."
    sleep "$CHECK_EVERY_SECONDS"
    waited=$(( waited + CHECK_EVERY_SECONDS ))
  done

  # 3. The new mode in weather-vm.yml: the Vagrantfile passes it to the VMs as APP_MODE.
  sed -i "s/^app_mode: *[a-z]*/app_mode: $new_mode/" weather-vm.yml
  echo "weather-vm.yml: app_mode: $new_mode"
fi

# 4. weather-vm: db-mode lets the role of Fetcher log in to PostgreSQL (or not), and
#    db-firewall opens port 5432 to fetcher-vm (or closes it) — both depend on the mode.
#    Order: Fetcher may connect to PostgreSQL only after both allow it (postgres),
#    and they close its old connection only after it runs in the new mode (rabbitmq).
if [[ "$new_mode" == "postgres" ]]; then
  vagrant provision weather-vm --provision-with db-mode,db-firewall
fi
vagrant provision fetcher-vm --provision-with fetcher
vagrant provision history-vm --provision-with history
if [[ "$new_mode" == "rabbitmq" ]]; then
  vagrant provision weather-vm --provision-with db-mode,db-firewall
fi
echo "Mode $new_mode is applied"

# 5. The result. A failed check does not undo the switch: the output says what to look at.
./healthcheck.sh
