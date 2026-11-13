#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [hours=24] [step_seconds=60]" >&2
  exit 2
}

HOURS=${1:-24}
STEP=${2:-60}
[[ $HOURS =~ ^[1-9][0-9]*$ && $STEP =~ ^[1-9][0-9]*$ ]] || usage

source "$(dirname "$0")/lib.sh"
need jq curl ssh
config_check
API=$(cfg '.app.FETCHER_ISS_API_URL // ""')
[[ -n $API ]] || die "app.FETCHER_ISS_API_URL not found in $CONFIG"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

end=$(( $(date +%s) / STEP * STEP ))
start=$(( end - HOURS * 3600 ))
total=$(( (end - start) / STEP + 1 ))
batches=$(( (total + 9) / 10 ))

printf '==> Fetching %d positions (%dh, every %ds) in %d requests, about %ds\n' \
  "$total" "$HOURS" "$STEP" "$batches" "$(( batches * 6 / 5 ))"

n=0
for (( t = start; t <= end; t += STEP * 10 )); do
  ts=$t
  for (( k = 1; k < 10 && t + k * STEP <= end; k++ )); do
    ts+=",$(( t + k * STEP ))"
  done
  curl -fsS --retry 10 --retry-delay 3 --retry-all-errors \
    "$API/positions?units=kilometers&timestamps=$ts" >>"$TMP/positions.jsonl"
  echo >>"$TMP/positions.jsonl"
  n=$(( n + 1 ))
  (( n % 20 == 0 || n == batches )) && printf '    %d/%d requests\n' "$n" "$batches"
  sleep 1.1
done

while IFS= read -r line; do
  [[ -n $line ]] || continue
  cat <<SQL
INSERT INTO positions (name, sat_id, latitude, longitude, altitude, velocity, visibility, footprint,
                       timestamp, daynum, solar_lat, solar_lon, units)
SELECT p.name, p.id, p.latitude, p.longitude, p.altitude, p.velocity, p.visibility, p.footprint,
       to_timestamp(p.timestamp) AT TIME ZONE 'UTC', p.daynum, p.solar_lat, p.solar_lon, p.units
  FROM json_to_recordset(\$json\$${line}\$json\$) AS p(
         name text, id int, latitude float8, longitude float8, altitude float8, velocity float8,
         visibility text, footprint float8, timestamp bigint, daynum float8, solar_lat float8,
         solar_lon float8, units text)
 WHERE NOT EXISTS (SELECT 1 FROM positions x WHERE x.timestamp = to_timestamp(p.timestamp) AT TIME ZONE 'UTC');
SQL
done <"$TMP/positions.jsonl" >"$TMP/backfill.sql"

HISTORY_HOST=${ISS_HISTORY_HOST:-gcp-$(cfg '.project.name_prefix')-history}
REMOTE=$(cat <<'EOF'
sudo /usr/local/sbin/iss-run bash -c 'docker run --rm -i --network iss_default --env-file <(docker inspect --format "{{range .Config.Env}}{{println .}}{{end}}" iss-history-1 | grep -E "^(POSTGRES_HOST|POSTGRES_USER|POSTGRES_DB|POSTGRES_PORT)=") -e POSTGRES_HISTORY_PASSWORD postgres:18-alpine sh -c '"'"'[ -z "$POSTGRES_HISTORY_PASSWORD" ] || export PGPASSWORD="$POSTGRES_HISTORY_PASSWORD"; psql -X -w -1 -v ON_ERROR_STOP=1 -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB"'"'"''
EOF
)
echo "==> Inserting into Postgres from $HISTORY_HOST"
ssh -o BatchMode=yes "$HISTORY_HOST" "$REMOTE" \
  <"$TMP/backfill.sql" | awk '$1 == "INSERT" { n += $3 } END { printf "    %d new positions inserted, the rest were already present\n", n }'
