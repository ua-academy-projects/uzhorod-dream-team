#!/bin/sh
set -eu

# Forward commands other than up directly to Goose.
if [ "${1:-up}" != up ]; then
  exec /goose "$@"
fi

# Create runtime users and update their passwords in Cloud SQL.
if [ "${CLOUD_SQL:-false}" = true ]; then
  psql "$GOOSE_DBSTRING" -v ON_ERROR_STOP=1 <<-'SQL'
	SELECT 'CREATE ROLE kyiv_air LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='kyiv_air') \gexec
	\getenv history_password HISTORY_DB_PASSWORD
	ALTER ROLE kyiv_air WITH PASSWORD :'history_password';
	SQL

  # Fetcher needs a database user only when it consumes PGMQ queues.
  if [ "${POSTGRES_ONLY:-false}" = true ]; then
    psql "$GOOSE_DBSTRING" -v ON_ERROR_STOP=1 <<-'SQL'
		SELECT 'CREATE ROLE kyiv_air_fetcher LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='kyiv_air_fetcher') \gexec
		\getenv fetcher_password FETCHER_DB_PASSWORD
		ALTER ROLE kyiv_air_fetcher WITH PASSWORD :'fetcher_password';
		SQL
  fi
fi

# Install PGMQ once, serializing concurrent installers with a transaction lock (random number).
if [ "${POSTGRES_ONLY:-false}" = true ]; then
  psql "$GOOSE_DBSTRING" -v ON_ERROR_STOP=1 <<-'SQL'
	BEGIN;
	SELECT pg_advisory_xact_lock(192837465);
	SELECT NOT EXISTS (SELECT FROM pg_namespace WHERE nspname = 'pgmq') AS install_pgmq \gset
	\if :install_pgmq
	\i /pgmq/pgmq.sql
	  CREATE TABLE pgmq.kyiv_air_installation (version text PRIMARY KEY);
	  INSERT INTO pgmq.kyiv_air_installation VALUES ('1.13.0');
	\endif
	COMMIT;
	SQL
fi

# Apply the application schema before granting runtime access.
/goose up

# Grant History access to application data, excluding migration bookkeeping.
if [ "${CLOUD_SQL:-false}" = true ]; then
  psql "$GOOSE_DBSTRING" -v ON_ERROR_STOP=1 <<-'SQL'
	REVOKE CREATE ON SCHEMA public FROM PUBLIC;
	GRANT USAGE ON SCHEMA public TO kyiv_air;
	GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO kyiv_air;
	REVOKE ALL ON goose_db_version FROM kyiv_air;
	GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO kyiv_air;
	ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kyiv_air;
	ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO kyiv_air;
	SQL
fi

# Create the request and reply queues for PostgreSQL-only mode.
if [ "${POSTGRES_ONLY:-false}" = true ]; then
  psql "$GOOSE_DBSTRING" -v ON_ERROR_STOP=1 <<-'SQL'
	SELECT pgmq.create('kyiv_air_requests');
	SELECT pgmq.create('kyiv_air_replies');
	SQL

  # Limit queue access to the operations used by History and Fetcher.
  if [ "${CLOUD_SQL:-false}" = true ]; then
    psql "$GOOSE_DBSTRING" -v ON_ERROR_STOP=1 <<-'SQL'
		REVOKE ALL ON SCHEMA pgmq FROM PUBLIC;
		REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA pgmq FROM PUBLIC;
		GRANT USAGE ON SCHEMA pgmq TO kyiv_air, kyiv_air_fetcher;
		GRANT SELECT, INSERT, UPDATE, DELETE ON pgmq.q_kyiv_air_requests, pgmq.q_kyiv_air_replies TO kyiv_air;
		GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA pgmq TO kyiv_air;
		GRANT SELECT, UPDATE, DELETE ON pgmq.q_kyiv_air_requests TO kyiv_air_fetcher;
		GRANT INSERT ON pgmq.q_kyiv_air_replies TO kyiv_air_fetcher;
		GRANT SELECT (msg_id) ON pgmq.q_kyiv_air_replies TO kyiv_air_fetcher;
		GRANT USAGE ON SEQUENCE pgmq.q_kyiv_air_replies_msg_id_seq TO kyiv_air_fetcher;
		SELECT format('GRANT EXECUTE ON FUNCTION %s TO kyiv_air, kyiv_air_fetcher', p.oid::regprocedure)
		FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
		WHERE n.nspname='pgmq' AND p.proname IN ('send','pop','read','delete','format_table_name') \gexec
		SQL
  fi
fi
