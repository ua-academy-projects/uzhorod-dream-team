#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed 's/\r$//' /tmp/kyiv-air-common.sh)

read_database
base_packages postgresql-16 postgresql-client-16
copy_env db
PG_CLUSTER=/etc/postgresql/16/main
PG_TEMP=$(mktemp)
HBA_TEMP=$(mktemp)
cat > "$PG_TEMP" <<PGCONF
# Managed by the Kyiv air multi-VM deployment.
listen_addresses = 'localhost,$PRIVATE_IP'
port = $SERVICE_PORT
password_encryption = 'scram-sha-256'
PGCONF

{
  printf '# BEGIN KYIV-AIR MULTINODE\n'
  printf 'host "%s" kyiv_air %s scram-sha-256\n' "$DB_NAME" "$LAN_SUBNET"
  printf '# END KYIV-AIR MULTINODE\n'
  awk '
    /^# BEGIN KYIV-AIR MULTINODE$/ { managed = 1; next }
    /^# END KYIV-AIR MULTINODE$/ { managed = 0; next }
    !managed { print }
  ' "$PG_CLUSTER/pg_hba.conf"
} > "$HBA_TEMP"

changed=false
install -d -m 0755 "$PG_CLUSTER/conf.d"
if ! cmp -s "$PG_TEMP" "$PG_CLUSTER/conf.d/kyiv-air.conf"; then
  install -o postgres -g postgres -m 0644 "$PG_TEMP" "$PG_CLUSTER/conf.d/kyiv-air.conf"
  changed=true
fi
if ! cmp -s "$HBA_TEMP" "$PG_CLUSTER/pg_hba.conf"; then
  install -o postgres -g postgres -m 0640 "$HBA_TEMP" "$PG_CLUSTER/pg_hba.conf"
  changed=true
fi
systemctl enable --now postgresql postgresql@16-main
if [[ "$changed" == true ]]; then
  systemctl restart postgresql@16-main
fi
wait_database

{
  printf '%s\n' "\\set password '$DB_PASSWORD'"
  cat <<'SQL'
SELECT 'CREATE ROLE kyiv_air LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kyiv_air') \gexec
SET password_encryption = 'scram-sha-256';
ALTER ROLE kyiv_air WITH PASSWORD :'password';
SELECT format('CREATE DATABASE %I OWNER kyiv_air', :'database') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'database') \gexec
SQL
} | runuser -u postgres -- psql -p "$SERVICE_PORT" -v ON_ERROR_STOP=1 -v database="$DB_NAME"

configure_firewall
