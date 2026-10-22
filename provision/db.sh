#!/usr/bin/env bash
# Provisioning of weather-vm: PostgreSQL only.
# Existing role, database and records are kept; running it again is safe.
set -euo pipefail

for name in WEATHER_DB_ROLE WEATHER_DB_NAME; do
  if [[ ! "${!name:-}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; then
    echo "$name must be a lowercase PostgreSQL identifier" >&2
    exit 1
  fi
done
if [[ ! "${WEATHER_DB_PASSWORD:-}" =~ ^[A-Za-z0-9]{16,}$ ]]; then
  echo "WEATHER_DB_PASSWORD must be at least 16 letters or digits" >&2
  exit 1
fi
for name in DB_IP HISTORY_IP; do
  if [[ ! "${!name:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$name must be an IPv4 address" >&2
    exit 1
  fi
done

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y postgresql

# Before Task 3 this VM also ran Fetcher and History. Now they live in their own VMs.
for service in weather-history weather-fetcher; do
  if [[ -e "/etc/systemd/system/$service.service" ]]; then
    systemctl disable --now "$service.service"
    rm -f "/etc/systemd/system/$service.service"
  fi
done
systemctl daemon-reload
rm -rf /opt/weather-history

# OS user with the same name as the role: applies the schema via the local socket (peer).
if ! id "$WEATHER_DB_ROLE" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "/var/lib/$WEATHER_DB_ROLE" \
    --shell /usr/sbin/nologin "$WEATHER_DB_ROLE"
fi

systemctl enable --now postgresql

# Restart PostgreSQL after a crash. The real server runs as postgresql@<version>-<cluster>
# (postgresql.service only starts it), so the drop-in is for that unit.
# The Ubuntu package default is Restart=no.
cluster=$(pg_lsclusters --no-header | awk 'NR == 1 { print $1 "-" $2 }')
if [[ -z "$cluster" ]]; then
  echo "PostgreSQL cluster not found" >&2
  exit 1
fi
install -d "/etc/systemd/system/postgresql@$cluster.service.d"
cat > "/etc/systemd/system/postgresql@$cluster.service.d/restart.conf" <<'EOF'
[Service]
Restart=on-failure
RestartSec=5s
EOF
systemctl daemon-reload

if ! runuser -u postgres -- psql -tAc \
  "SELECT 1 FROM pg_roles WHERE rolname = '$WEATHER_DB_ROLE'" | grep -qx 1; then
  runuser -u postgres -- createuser --login "$WEATHER_DB_ROLE"
fi
# psql reads the password from the environment (\getenv), not from its arguments.
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -v role="$WEATHER_DB_ROLE" <<'SQL'
\getenv password WEATHER_DB_PASSWORD
ALTER ROLE :"role" LOGIN PASSWORD :'password';
SQL

if ! runuser -u postgres -- psql -tAc \
  "SELECT 1 FROM pg_database WHERE datname = '$WEATHER_DB_NAME'" | grep -qx 1; then
  runuser -u postgres -- createdb --owner="$WEATHER_DB_ROLE" "$WEATHER_DB_NAME"
fi

runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
  -c "GRANT CONNECT, CREATE ON DATABASE \"$WEATHER_DB_NAME\" TO \"$WEATHER_DB_ROLE\""
runuser -u postgres -- psql -d "$WEATHER_DB_NAME" -v ON_ERROR_STOP=1 \
  -c "GRANT USAGE, CREATE ON SCHEMA public TO \"$WEATHER_DB_ROLE\""
# The role user cannot read /home/vagrant, so root opens the file and passes it via stdin.
runuser -u "$WEATHER_DB_ROLE" -- psql -d "$WEATHER_DB_NAME" -v ON_ERROR_STOP=1 \
  < /home/vagrant/weather-history/db/schema.sql
runuser -u postgres -- psql -d "$WEATHER_DB_NAME" -v ON_ERROR_STOP=1 \
  -c "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.weather_records TO \"$WEATHER_DB_ROLE\"; GRANT USAGE, SELECT ON SEQUENCE public.weather_records_id_seq TO \"$WEATHER_DB_ROLE\""

# Listen on the private network too, not only on localhost.
config_dir=$(dirname "$(runuser -u postgres -- psql -tAc 'SHOW config_file')")
cat > "$config_dir/conf.d/weather-history.conf" <<EOF
listen_addresses = 'localhost,$DB_IP'
EOF

# Only History VM, only this database and role, only with TLS and password.
hba_file=$(runuser -u postgres -- psql -tAc 'SHOW hba_file')
sed -i '/# weather-history$/d' "$hba_file"
echo "hostssl $WEATHER_DB_NAME $WEATHER_DB_ROLE $HISTORY_IP/32 scram-sha-256 # weather-history" \
  >> "$hba_file"

# listen_addresses changes only after a restart.
systemctl restart postgresql
