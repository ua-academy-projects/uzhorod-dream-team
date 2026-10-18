#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [hours=24] [step_seconds=60]" >&2
  exit 2
}

HOURS=${1:-24}
STEP=${2:-60}
[[ $HOURS =~ ^[1-9][0-9]*$ && $STEP =~ ^[1-9][0-9]*$ ]] || usage

ROOT=$(cd "$(dirname "$0")/.." && pwd)
API=$(sed -n 's/^FETCHER_ISS_API_URL=//p' "$ROOT/.env" | tr -d '\r')
[[ -n $API ]] || { echo "FETCHER_ISS_API_URL not found in $ROOT/.env" >&2; exit 1; }

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

echo "==> Inserting into iss-db"
ssh -o BatchMode=yes iss-db \
  "cd /opt/iss && sudo docker compose exec -T postgres sh -c 'psql -X -1 -v ON_ERROR_STOP=1 -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\"'" \
  <"$TMP/backfill.sql" | awk '$1 == "INSERT" { n += $3 } END { printf "    %d new positions inserted, the rest were already present\n", n }'
