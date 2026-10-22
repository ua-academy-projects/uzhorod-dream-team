#!/usr/bin/env bash
# Access of Fetcher to PostgreSQL in weather-vm, by APP_MODE (app_mode in weather-vm.yml):
#   postgres - the role weather_fetcher may log in, only from fetcher-vm, only with TLS;
#   rabbitmq - the role may not log in, its pg_hba line is removed, its sessions are closed.
# Also applies db/schema.sql, converts user_settings to hstore, schedules the pg_cron jobs,
# creates the pgmq queues and gives the roles their rights.
# PostgreSQL is not restarted: pg_hba and LOGIN are applied with a reload.
# Runs after provision/db-extensions.sh (it installs pgmq). Running it again is safe.
set -euo pipefail

if [[ "${APP_MODE:-}" != "rabbitmq" && "${APP_MODE:-}" != "postgres" ]]; then
  echo "APP_MODE must be rabbitmq or postgres" >&2
  exit 1
fi
for name in WEATHER_DB_ROLE WEATHER_DB_NAME; do
  if [[ ! "${!name:-}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; then
    echo "$name must be a lowercase PostgreSQL identifier" >&2
    exit 1
  fi
done
if [[ ! "${FETCHER_DB_PASSWORD:-}" =~ ^[A-Za-z0-9]{16,}$ ]]; then
  echo "FETCHER_DB_PASSWORD must be at least 16 letters or digits" >&2
  exit 1
fi
if [[ ! "${FETCHER_IP:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "FETCHER_IP must be an IPv4 address" >&2
  exit 1
fi

FETCHER_ROLE=weather_fetcher

# Runs SQL from stdin as postgres in the database of the app; stops on the first error.
psql_app() {
  runuser -u postgres -- psql -d "$WEATHER_DB_NAME" -v ON_ERROR_STOP=1 -q "$@"
}

# 1. Tables. The owner is the role of History (as in db.sh), so History has all rights on them.
runuser -u "$WEATHER_DB_ROLE" -- psql -d "$WEATHER_DB_NAME" -v ON_ERROR_STOP=1 -q \
  < /home/vagrant/weather-history/db/schema.sql

# 2. Before hstore, user_settings kept the settings as JSONB: they are converted once.
#    In one transaction (DO): if anything fails, the table stays as it was.
#    jsonb_each_text gives the pairs key/value, hstore(keys, values) puts them together.
runuser -u "$WEATHER_DB_ROLE" -- psql -d "$WEATHER_DB_NAME" -v ON_ERROR_STOP=1 -q <<'SQL'
DO $$
BEGIN
  IF (SELECT atttypid::regtype::text FROM pg_attribute
      WHERE attrelid = 'user_settings'::regclass AND attname = 'settings') = 'jsonb' THEN
    ALTER TABLE user_settings ADD COLUMN settings_hstore hstore;
    UPDATE user_settings SET settings_hstore = (
      SELECT coalesce(hstore(array_agg(key), array_agg(value)), ''::hstore)
      FROM jsonb_each_text(settings));
    ALTER TABLE user_settings DROP COLUMN settings;
    ALTER TABLE user_settings RENAME COLUMN settings_hstore TO settings;
    ALTER TABLE user_settings ALTER COLUMN settings SET NOT NULL;
    RAISE NOTICE 'user_settings: settings converted from JSONB to hstore';
  END IF;
END $$;
SQL

# 3. Jobs of pg_cron (they run inside PostgreSQL, see provision/db-extensions.sh).
#    weather-expired-settings: every 15 minutes removes settings not used for 30 days,
#      as the role of the app (the owner of user_settings) — like the TTL of Redis.
#    cron-history-cleanup: every night removes the log of the jobs older than 7 days
#      (pg_cron keeps a row for every run in cron.job_run_details).
#    A job with the same name is updated, not added again, so running it again is safe.
psql_app -v app_role="$WEATHER_DB_ROLE" <<'SQL' >/dev/null
SELECT cron.schedule_in_database(
  'weather-expired-settings', '*/15 * * * *',
  'DELETE FROM user_settings WHERE expires_at <= now()',
  current_database(), :'app_role');
SELECT cron.schedule(
  'cron-history-cleanup', '0 3 * * *',
  $$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '7 days'$$);
SQL

# 4. Queues of pgmq (the same names as the RabbitMQ queues, with _ instead of .).
#    pgmq.create makes the tables pgmq.q_<queue> (messages) and pgmq.a_<queue> (archive);
#    it does nothing if the queue already exists.
#    The old queue tables (before pgmq) are removed: they kept only messages in transit
#    (requests and answers of the last minutes), never the weather itself.
psql_app <<'SQL' >/dev/null
DROP TABLE IF EXISTS public.weather_requests, public.weather_responses;
SELECT pgmq.create('weather_requests');
SELECT pgmq.create('weather_responses');
SQL

# 5. The roles and their rights: only what each service does with the queues.
#    The functions of pgmq work with the rights of the role that calls them,
#    so the roles get rights on the tables of the queues:
#      pgmq.send   - INSERT;  pgmq.read - SELECT, UPDATE (vt and read_ct);
#      pgmq.delete - DELETE;  FOR UPDATE (lock of a row) - UPDATE.
#    History:  weather_requests - send, remove old requests; weather_responses - read, remove.
#    Fetcher:  weather_requests - read, check its lease, remove; weather_responses - only send.
#    Fetcher has no rights on weather_records and user_settings.
#    By default every role (PUBLIC) may connect to a database and make temporary tables;
#    this is taken away, so only the roles named here may connect.
psql_app -v app_role="$WEATHER_DB_ROLE" -v fetcher="$FETCHER_ROLE" -v db="$WEATHER_DB_NAME" <<'SQL'
SELECT format('CREATE ROLE %I NOLOGIN', :'fetcher')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'fetcher') \gexec

REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO :"app_role", :"fetcher";
GRANT USAGE ON SCHEMA public TO :"fetcher";
REVOKE ALL ON weather_records, user_settings FROM :"fetcher";

GRANT USAGE ON SCHEMA pgmq TO :"app_role", :"fetcher";
REVOKE ALL ON pgmq.q_weather_requests, pgmq.q_weather_responses FROM :"app_role", :"fetcher";
GRANT SELECT, INSERT, UPDATE, DELETE ON pgmq.q_weather_requests TO :"app_role";
GRANT SELECT, UPDATE, DELETE ON pgmq.q_weather_responses TO :"app_role";
GRANT SELECT, UPDATE, DELETE ON pgmq.q_weather_requests TO :"fetcher";
GRANT INSERT ON pgmq.q_weather_responses TO :"fetcher";
-- pgmq.send ends with INSERT ... RETURNING msg_id, and RETURNING needs the SELECT right.
-- Only this column: Fetcher cannot read the answers themselves.
GRANT SELECT (msg_id) ON pgmq.q_weather_responses TO :"fetcher";

-- A transaction left open (for example, Fetcher hangs) is closed after 30 seconds,
-- so it does not keep rows locked; one statement may run at most 10 seconds.
ALTER ROLE :"fetcher" SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE :"fetcher" SET statement_timeout = '10s';
SQL

# 6. Login of the role and its line in pg_hba.conf — only in mode postgres.
hba_file=$(runuser -u postgres -- psql -tAc 'SHOW hba_file')
marker="# weather-history fetcher"
sed -i "/$marker\$/d" "$hba_file"

if [[ "$APP_MODE" == "postgres" ]]; then
  # psql reads the password from the environment (\getenv), not from its arguments.
  psql_app -v fetcher="$FETCHER_ROLE" <<'SQL'
\getenv password FETCHER_DB_PASSWORD
ALTER ROLE :"fetcher" LOGIN PASSWORD :'password';
SQL
  # Only fetcher-vm, only this database and role, only with TLS and password.
  echo "hostssl $WEATHER_DB_NAME $FETCHER_ROLE $FETCHER_IP/32 scram-sha-256 $marker" >> "$hba_file"
else
  psql_app -v fetcher="$FETCHER_ROLE" <<'SQL'
ALTER ROLE :"fetcher" NOLOGIN PASSWORD NULL;
SQL
fi

# reload: PostgreSQL reads pg_hba.conf again; open sessions of other roles are kept.
psql_app -c "SELECT pg_reload_conf()" >/dev/null

# In mode rabbitmq Fetcher must not keep a connection that was opened before.
if [[ "$APP_MODE" == "rabbitmq" ]]; then
  psql_app -v fetcher="$FETCHER_ROLE" <<'SQL' >/dev/null
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = :'fetcher';
SQL
fi

echo "app_mode: $APP_MODE"
echo "role $FETCHER_ROLE can log in: $(runuser -u postgres -- psql -tAc \
  "SELECT rolcanlogin FROM pg_roles WHERE rolname = '$FETCHER_ROLE'")"
echo "pg_hba lines for $FETCHER_ROLE: $(grep -c "$marker\$" "$hba_file" || true)"
