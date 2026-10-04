#!/usr/bin/env bash
# Run with Bash: brace expansions and [[ ... ]] checks are used below.
# -E inherits ERR traps in functions/subshells; -e stops on unhandled command failures.
# -u rejects unset variables; pipefail reports failures anywhere in a pipeline.
set -Eeuo pipefail

# Vagrant rsyncs source here. Built Go binaries live under APP/bin, while CONFIG
# holds root-only runtime env files and the persistent generated database password.
SOURCE=/opt/kyiv-air/source
APP=/opt/kyiv-air
CONFIG=/etc/kyiv-air
# Keep Node on major version 24, and pin the pnpm and migration-tool versions.
NODE_MAJOR=24
PNPM_VERSION=10.33.0
GOOSE_VERSION=3.24.3
# Prevent package configuration prompts during unattended provisioning.
export DEBIAN_FRONTEND=noninteractive
# Prefer APT-installed executables over older manual installs in /usr/local/bin.
# Include administrative commands in sbin and globally installed pnpm/Goose.
export PATH="/usr/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/bin:/sbin"
# Ubuntu's Go package can download newer toolchains required by the services' go.mod files.
export GOTOOLCHAIN=auto

# The Vagrant file provisioners upload these files before this script runs as root.
# Remove temporary uploads on exit, including error exits, because they contain credentials.
trap 'rm -f /tmp/kyiv-air-{fetcher,history,db,ui}.env "${PG_CONFIG_TEMP:-}" "${PG_HBA_TEMP:-}"' EXIT
# -s requires each upload to exist and contain data before packages or services are changed.
for service in fetcher history db ui; do
  if [[ ! -s "/tmp/kyiv-air-$service.env" ]]; then
    echo "Missing $service env file. Run vagrant provision to upload deployment/vagrant-singlenode/env/$service.env." >&2
    exit 1
  fi
done

# Only read a literal API key. Never execute the host's configuration as shell code.
# sed selects the key's value; tr removes carriage returns from Windows line endings.
OPENAQ_API_KEY=$(sed -n 's/^OPENAQ_API_KEY=//p' /tmp/kyiv-air-fetcher.env | tr -d '\r')
# Accept the supported unquoted key format and reject the documented placeholder.
# This checks configuration format, not whether OpenAQ will accept the key.
if [[ ! "$OPENAQ_API_KEY" =~ ^[A-Za-z0-9_-]+$ || "$OPENAQ_API_KEY" == "your_openaq_api_key_here" ]]; then
  echo "Set an actual unquoted OPENAQ_API_KEY in deployment/vagrant-singlenode/env/fetcher.env." >&2
  exit 1
fi
# Read the database name as data too. Its restricted format also fits safely into the URL.
DB_NAME=$(sed -n 's/^POSTGRES_DB=//p' /tmp/kyiv-air-db.env | tr -d '\r')
if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
  echo "POSTGRES_DB in env/db.env must be an unquoted database name using lowercase letters, digits, and underscores." >&2
  exit 1
fi

# Ubuntu supplies Go and the runtime services; Node uses the NodeSource APT repository.
# Refresh package metadata, then install only requested packages and their dependencies.
# Certificates/curl/GnuPG support HTTPS downloads and repository signatures; git and
# build-essential support dependency builds. rsync copies
# source. PostgreSQL includes the server and CLI tools; UFW manages the guest firewall.
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg git build-essential golang-go rsync \
  postgresql-16 postgresql-client-16 ufw

# The selected Vagrant box and the Node repository entry below both target amd64.
if [[ $(uname -m) != "x86_64" ]]; then
  echo "This deployment uses an amd64 box and requires an x86_64 guest." >&2
  exit 1
fi

# Node runs Vite's development server.
# Create a readable keyring directory. Download NodeSource's signing key over HTTPS,
# convert its armored representation to a binary GPG keyring, and allow APT to read it.
# curl fails on HTTP errors and retries downloads; GPG runs without interactive prompts.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL --retry 3 https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg
chmod 0644 /etc/apt/keyrings/nodesource.gpg
# Register the Node 24 repository and scope its signing key to this repository only.
# NodeSource uses the distribution-independent suite name "nodistro".
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list
# Priority 600 makes NodeSource's nodejs package preferred over the normal priority 500.
# The quoted heredoc delimiter keeps the following APT configuration literal.
cat > /etc/apt/preferences.d/nodejs <<'APT'
Package: nodejs
Pin: origin deb.nodesource.com
Pin-Priority: 600
APT
# Refresh metadata again now that NodeSource is registered, then install its nodejs package.
apt-get update
apt-get install -y --no-install-recommends nodejs
# Forget Bash's cached executable paths, then ensure the selected Node major is correct.
hash -r
if [[ $(node --version) != v${NODE_MAJOR}.* ]]; then
  echo "Expected Node ${NODE_MAJOR}.x from NodeSource after installing nodejs." >&2
  exit 1
fi
# Install the pinned pnpm globally only when it is missing or its version differs.
if ! command -v pnpm >/dev/null || [[ $(pnpm --version) != "$PNPM_VERSION" ]]; then
  npm install --global "pnpm@$PNPM_VERSION"
fi
# Install Goose into the global executable directory; omit drivers for unused databases.
# PostgreSQL support stays enabled. Skip installation when the requested version exists.
if [[ ! -x /usr/local/bin/goose ]] || ! goose --version | grep -q "${GOOSE_VERSION}"; then
  GOBIN=/usr/local/bin go install -tags='no_clickhouse no_libsql no_mssql no_mysql no_sqlite3 no_vertica no_ydb' \
    "github.com/pressly/goose/v3/cmd/goose@v${GOOSE_VERSION}"
fi

# Build as the Vagrant user so generated files and caches remain owned by that user.
# Create the final binary directory, but stage new executables in /tmp until both builds finish.
install -d -m 0755 "$APP/bin"
# Explicitly pass PATH and Go's toolchain setting into each unprivileged build.
# For bash -c, the extra "bash" argument supplies $0; the directory and service are $1/$2.
# The nested shell has its own set -e so a failed cd cannot build from the wrong directory.
# -trimpath removes build-machine filesystem paths from the executable.
for service in fetcher history; do
  runuser -u vagrant -- env PATH="$PATH" GOTOOLCHAIN="$GOTOOLCHAIN" bash -c \
    'set -e; cd "$1"; go build -trimpath -o /tmp/kyiv-air-"$2" ./cmd/"$2"' \
    bash "$SOURCE/$service" "$service"
done
# Install UI dependencies without changing the committed lockfile. Vite will serve source;
# no production UI build is needed. Its node_modules and caches also belong to vagrant.
runuser -u vagrant -- env PATH="$PATH" bash -c \
  'set -e; cd "$1"; pnpm install --frozen-lockfile' bash "$SOURCE/ui"

# Create the backend runtime account only if absent. It has its own group and no login shell.
# Its configured home is APP; the backend services do not run as root or the Vagrant user.
id kyiv-air >/dev/null 2>&1 || useradd --system --user-group --home-dir "$APP" --shell /usr/sbin/nologin kyiv-air
# Mode 0700 limits access to the configuration directory to root.
install -d -m 0700 "$CONFIG"

# Preserve the generated password across provisioning so the existing DB remains usable.
# Generate 32 random bytes as hex only if the password file is absent or empty.
# Use Node's built-in cryptographic random generator; no extra package is required.
# Hex avoids characters that would require escaping in the PostgreSQL connection URL.
if [[ ! -s "$CONFIG/db-password" ]]; then
  node -e 'console.log(require("node:crypto").randomBytes(32).toString("hex"))' > "$CONFIG/db-password"
fi
# Mode 0600 permits only root to read/write the saved password.
chmod 0600 "$CONFIG/db-password"
DB_PASSWORD=$(cat "$CONFIG/db-password")
# History connects through guest loopback. TLS is disabled for this local connection;
# this localhost is inside the VM, distinct from browser requests to host forwarded ports.
DATABASE_URL="postgres://kyiv_air:${DB_PASSWORD}@127.0.0.1:5432/${DB_NAME}?sslmode=disable"

# Copy fresh files on every run, then append only the generated database connection.
# install sets file permissions while copying. This preserves the local env file contents
# and resets the runtime copies on reprovisioning, preventing generated lines accumulating.
for service in fetcher history db ui; do
  install -m 0600 "/tmp/kyiv-air-$service.env" "$CONFIG/$service.env"
done
# The generated URL takes precedence; the source history.env does not need credentials.
printf '\nDATABASE_URL=%s\n' "$DATABASE_URL" >> "$CONFIG/history.env"

# Stop the old application only after all builds succeed. PostgreSQL configuration may
# require a restart, so stop History before changing its database server's listener.
# Units may not exist on the first run; ignore missing units. Existing data is retained.
systemctl stop kyiv-air-ui.service kyiv-air-history.service kyiv-air-fetcher.service 2>/dev/null || true

# Ubuntu's main cluster reads conf.d/*.conf. Use a separate managed file instead of
# rewriting its packaged settings. Both providers forward to a guest network interface,
# so PostgreSQL must accept TCP connections beyond loopback; History still uses loopback.
PG_CLUSTER=/etc/postgresql/16/main
PG_CONFIG_TEMP=$(mktemp)
PG_HBA_TEMP=$(mktemp)
install -d -m 0755 "$PG_CLUSTER/conf.d"
cat > "$PG_CONFIG_TEMP" <<'PGCONF'
# Managed by Kyiv air provisioning: accept forwarded connections from either provider.
listen_addresses = '*'
password_encryption = 'scram-sha-256'
PGCONF

# Prepend one managed authentication block, removing its previous copy on each run.
# Quote the database name to match it literally, including names such as "all".
# samenet accepts directly connected subnets without assuming a provider-specific IP.
# Only this database and application role get this rule; SCRAM requires the saved password.
# Keep all other rules, including local administrator peer authentication, untouched.
{
  printf '# BEGIN KYIV-AIR MANAGED ACCESS\n'
  printf 'host "%s" kyiv_air samenet scram-sha-256\n' "$DB_NAME"
  printf '# END KYIV-AIR MANAGED ACCESS\n'
  awk '
    /^# BEGIN KYIV-AIR MANAGED ACCESS$/ { managed = 1; next }
    /^# END KYIV-AIR MANAGED ACCESS$/ { managed = 0; next }
    !managed { print }
  ' "$PG_CLUSTER/pg_hba.conf"
} > "$PG_HBA_TEMP"

# Compare staged files before installing them; an unchanged reprovision needs no restart.
# PostgreSQL must be able to read these files; HBA contents have no stored credentials.
PG_CONFIG_CHANGED=false
if ! cmp -s "$PG_CONFIG_TEMP" "$PG_CLUSTER/conf.d/kyiv-air.conf"; then
  install -o postgres -g postgres -m 0644 "$PG_CONFIG_TEMP" "$PG_CLUSTER/conf.d/kyiv-air.conf"
  PG_CONFIG_CHANGED=true
fi
if ! cmp -s "$PG_HBA_TEMP" "$PG_CLUSTER/pg_hba.conf"; then
  install -o postgres -g postgres -m 0640 "$PG_HBA_TEMP" "$PG_CLUSTER/pg_hba.conf"
  PG_CONFIG_CHANGED=true
fi

# Enable PostgreSQL for future boots and start Ubuntu's actual version-16 main cluster now.
systemctl enable --now postgresql postgresql@16-main
# listen_addresses requires a restart; do this only when managed configuration changed.
if [[ "$PG_CONFIG_CHANGED" == true ]]; then
  systemctl restart postgresql@16-main
fi
# Fail if PostgreSQL is not accepting connections; -q suppresses normal status output.
pg_isready -q

# Run as the PostgreSQL administrator and stop psql at the first SQL error.
# The role name is fixed; the database name comes from env/db.env.
# The quoted heredoc prevents Bash expansion. psql's :'name' quotes variable values
# as SQL literals, and format(... %I ...) quotes the database name as an identifier.
# Each SELECT produces CREATE SQL only if its object is absent; \gexec executes that SQL.
# Restore the role's saved password on every run without dropping existing data.
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -v password="$DB_PASSWORD" -v database="$DB_NAME" <<'SQL'
SELECT 'CREATE ROLE kyiv_air LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kyiv_air') \gexec
SET password_encryption = 'scram-sha-256';
ALTER ROLE kyiv_air WITH PASSWORD :'password';
SELECT format('CREATE DATABASE %I OWNER kyiv_air', :'database') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'database') \gexec
SQL

# Goose applies only pending Up migrations and records applied versions in PostgreSQL.
# These environment variables apply to this command, keeping the URL out of its arguments.
GOOSE_DRIVER=postgres GOOSE_DBSTRING="$DATABASE_URL" \
  goose -dir "$SOURCE/history/internal/db/migrations" up
# Replace the stopped services' binaries with executable mode 0755, then remove staging files.
for service in fetcher history; do
  install -m 0755 "/tmp/kyiv-air-$service" "$APP/bin/$service"
  rm -f "/tmp/kyiv-air-$service"
done

# systemd starts these services on boot and restarts them if they crash.
# Recreate unit files on every run so changed paths/settings take effect after daemon-reload.
for service in fetcher history; do
  DEPENDENCIES="network-online.target"
  REQUIRED_SERVICES=""
  START_CHECK=""
  # History asks systemd to start PostgreSQL and Fetcher, orders itself after them,
  # and checks Fetcher's HTTP heartbeat before launching its own process.
  # Ordering alone does not guarantee HTTP readiness, which is why the curl check is needed.
  if [[ "$service" == "history" ]]; then
    DEPENDENCIES="$DEPENDENCIES postgresql@16-main.service kyiv-air-fetcher.service"
    REQUIRED_SERVICES="Wants=postgresql@16-main.service kyiv-air-fetcher.service"
    START_CHECK="ExecStartPre=/usr/bin/curl -fsS --retry 20 --retry-connrefused --retry-delay 1 http://127.0.0.1:8080/health"
  fi
  # This unquoted heredoc expands the script's paths and service-specific settings.
  # [Unit]: Description labels the unit; Wants requests network/dependency startup;
  # After sets startup order. StartLimitIntervalSec=0 disables restart rate limiting.
  # [Service]: Type=simple tracks the foreground Go process. User/Group drop privileges.
  # WorkingDirectory avoids source env files; EnvironmentFile is read by systemd before
  # dropping privileges. ExecStartPre (History only) gates startup; ExecStart runs the binary.
  # Restart=on-failure retries failed processes after five seconds.
  # NoNewPrivileges blocks privilege gains; ProtectSystem=strict makes the filesystem
  # read-only; ProtectHome hides home directories; PrivateTmp gives an isolated temp area.
  # [Install]: WantedBy=multi-user.target makes enable start the service during normal boot.
  cat > "/etc/systemd/system/kyiv-air-$service.service" <<UNIT
[Unit]
Description=Kyiv air quality $service service
Wants=network-online.target
$REQUIRED_SERVICES
After=$DEPENDENCIES
StartLimitIntervalSec=0

[Service]
Type=simple
User=kyiv-air
Group=kyiv-air
WorkingDirectory=$APP
EnvironmentFile=$CONFIG/$service.env
$START_CHECK
ExecStart=$APP/bin/$service
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
done

# Run Vite as the source owner so it can update its dependency and transform caches.
# Request History startup and order Vite after it. This is ordering, not an API readiness test.
# The unit uses the same restart policy, startup target, and private temp area as the backends.
# Its source directory and unprivileged user differ; it needs writable development caches.
# Environment supplies executable lookup paths, and EnvironmentFile loads the UI settings.
# /usr/bin/env finds pnpm on PATH. --host accepts guest-interface connections, --port fixes
# the dev port, and --strictPort prevents silently switching ports if 5173 is occupied.
# Node/Vite remain in the foreground for systemd to supervise; no API proxy is configured.
cat > /etc/systemd/system/kyiv-air-ui.service <<UNIT
[Unit]
Description=Kyiv air quality Vite development server
Wants=network-online.target kyiv-air-history.service
After=network-online.target kyiv-air-history.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=vagrant
Group=vagrant
WorkingDirectory=$SOURCE/ui
Environment="PATH=$PATH"
EnvironmentFile=$CONFIG/ui.env
ExecStart=/usr/bin/env pnpm run dev --host 0.0.0.0 --port 5173 --strictPort
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

# Reload unit definitions after writing them; enable --now registers boot startup and starts
# each service. Fetcher becomes healthy before History starts its initial collection routine.
systemctl daemon-reload
systemctl enable --now kyiv-air-fetcher
# Fail on HTTP errors, show failures without progress output, and retry connection refusals
# or supported transient HTTP errors up to 20 times with a one-second delay.
curl -fsS --retry 20 --retry-connrefused --retry-delay 1 http://127.0.0.1:8080/health >/dev/null
systemctl enable --now kyiv-air-history
systemctl enable --now kyiv-air-ui

# Both providers target guest network listeners, which an active UFW firewall must allow.
# Keep SSH accessible, deny other incoming traffic, and permit outbound downloads/API calls.
# Adding rules is idempotent. Preserve the existing active/inactive state; do not enable UFW.
# Host forwarding binds to localhost, but these rules also allow access from the VM network.
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
for port in 5173 8080 8081 5432; do
  ufw allow "$port/tcp"
done

# Check History's database-backed API and Vite directly inside the guest, allowing startup
# retries. These checks do not verify host forwarding or successful data collection from OpenAQ.
curl -fsS --retry 20 --retry-connrefused --retry-delay 1 http://127.0.0.1:8081/api/v1/locations >/dev/null
curl -fsS --retry 20 --retry-connrefused --retry-delay 1 http://127.0.0.1:5173/ >/dev/null
# Print the host-facing URL; History continues its backfill and polling in the background.
echo "Application ready at http://localhost:5173 on the host. History is collecting OpenAQ data in the background."
