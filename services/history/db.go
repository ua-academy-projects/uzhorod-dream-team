package main

import (
	"database/sql"
	"log/slog"
	"net"
	"net/url"
	"time"

	"github.com/lib/pq"
)

func initDB() {
	connURL := url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(cfg.PostgresUser, cfg.PostgresPassword),
		Host:     net.JoinHostPort(cfg.PostgresHost, cfg.PostgresPort),
		Path:     "/" + cfg.PostgresDB,
		RawQuery: "sslmode=disable",
	}
	dbURL = connURL.String()

	var err error
	db, err = sql.Open("postgres", dbURL)
	if err != nil {
		fatal("postgres config invalid", "err", err)
	}

	const attempts = 20
	for i := 1; i <= attempts; i++ {
		if err = db.Ping(); err == nil {
			break
		}
		slog.Warn("postgres not ready", "attempt", i, "of", attempts, "err", err)
		time.Sleep(3 * time.Second)
	}
	if err != nil {
		fatal("postgres connect failed", "err", err)
	}
	slog.Info("postgres connected")
}

func migrate() {
	statements := []string{
		`CREATE TABLE IF NOT EXISTS positions (
			id SERIAL PRIMARY KEY, name VARCHAR(50), sat_id INT, latitude FLOAT, longitude FLOAT,
			altitude FLOAT, velocity FLOAT, visibility VARCHAR(50), footprint FLOAT,
			timestamp TIMESTAMP, daynum FLOAT, solar_lat FLOAT, solar_lon FLOAT, units VARCHAR(20)
		)`,
		`CREATE TABLE IF NOT EXISTS position_queue (
			id BIGSERIAL PRIMARY KEY,
			payload JSONB NOT NULL,
			enqueued_at TIMESTAMPTZ NOT NULL DEFAULT now()
		)`,
		`CREATE OR REPLACE FUNCTION position_queue_notify() RETURNS trigger LANGUAGE plpgsql AS $$
		BEGIN
			PERFORM pg_notify('` + queueChannel + `', '');
			RETURN NULL;
		END
		$$`,
		`CREATE OR REPLACE TRIGGER position_queue_notify AFTER INSERT ON position_queue
			FOR EACH STATEMENT EXECUTE FUNCTION position_queue_notify()`,
		`CREATE TABLE IF NOT EXISTS sessions (
			session_id UUID PRIMARY KEY,
			theme TEXT NOT NULL,
			expires_at TIMESTAMPTZ NOT NULL
		)`,
		`ALTER TABLE sessions
			ADD COLUMN IF NOT EXISTS latitude DOUBLE PRECISION,
			ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION,
			ADD COLUMN IF NOT EXISTS radius_km DOUBLE PRECISION`,
		`CREATE INDEX IF NOT EXISTS positions_timestamp_idx ON positions (timestamp)`,
		`CREATE EXTENSION IF NOT EXISTS pgmq`,
		`CREATE EXTENSION IF NOT EXISTS hstore`,
		`CREATE EXTENSION IF NOT EXISTS pg_cron`,
		`SELECT pgmq.create('` + pgmqQueue + `')`,
		`CREATE UNLOGGED TABLE IF NOT EXISTS kv_sessions (
			session_id UUID PRIMARY KEY,
			data hstore NOT NULL,
			expires_at TIMESTAMPTZ NOT NULL
		)`,
		`SELECT cron.schedule('iss-expire-sessions', '* * * * *',
			$$DELETE FROM kv_sessions WHERE expires_at <= now()$$)`,
		`SELECT cron.schedule('iss-purge-queue-archive', '17 * * * *',
			$$DELETE FROM pgmq.a_` + pgmqQueue + ` WHERE archived_at < now() - interval '1 day'$$)`,
	}
	for _, statement := range statements {
		if _, err := db.Exec(statement); err != nil {
			fatal("schema migration failed", "err", err)
		}
	}
	slog.Info("schema ready",
		"tables", "positions, position_queue, sessions, kv_sessions",
		"extensions", "pgmq, hstore, pg_cron", "pgmq_queue", pgmqQueue)
	grantFetcherRole()
}

func grantFetcherRole() {
	var exists bool
	if err := db.QueryRow(`SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1)`, cfg.FetcherRole).Scan(&exists); err != nil {
		fatal("fetcher role lookup failed", "err", err)
	}
	if !exists {
		slog.Warn("fetcher role not found, queue grants skipped", "role", cfg.FetcherRole)
		return
	}

	role := pq.QuoteIdentifier(cfg.FetcherRole)
	for _, statement := range []string{
		"GRANT INSERT ON position_queue TO " + role,
		"GRANT USAGE ON SEQUENCE position_queue_id_seq TO " + role,
		"GRANT USAGE ON SCHEMA pgmq TO " + role,
		"GRANT INSERT, SELECT (msg_id) ON pgmq.q_" + pgmqQueue + " TO " + role,
		"GRANT USAGE ON SEQUENCE pgmq.q_" + pgmqQueue + "_msg_id_seq TO " + role,
	} {
		if _, err := db.Exec(statement); err != nil {
			fatal("fetcher role grant failed", "role", cfg.FetcherRole, "err", err)
		}
	}
	slog.Info("fetcher role may insert into queues", "role", cfg.FetcherRole, "queues", "position_queue, pgmq "+pgmqQueue)
}
