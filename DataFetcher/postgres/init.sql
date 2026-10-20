-- Idempotent schema for a fresh DataFetcher PostgreSQL instance.
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pgmq;

CREATE TABLE IF NOT EXISTS history (
    id BIGSERIAL PRIMARY KEY,
    source TEXT NOT NULL DEFAULT 'btc',
    value DOUBLE PRECISION NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL,
    metadata TEXT
);
CREATE INDEX IF NOT EXISTS idx_history_recorded_at ON history (recorded_at);
CREATE INDEX IF NOT EXISTS idx_history_source_time ON history (source, recorded_at DESC);

CREATE TABLE IF NOT EXISTS user_preferences (
    session_id TEXT PRIMARY KEY,
    preferences HSTORE NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_user_preferences_updated_at ON user_preferences (updated_at DESC);

CREATE TABLE IF NOT EXISTS fetcher_tasks (
    id BIGSERIAL PRIMARY KEY,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    result JSONB,
    error TEXT,
    queue_enqueued BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_fetcher_tasks_pending ON fetcher_tasks (id) WHERE status = 'pending';

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fetcher_worker') THEN
        CREATE ROLE fetcher_worker LOGIN;
    ELSE
        ALTER ROLE fetcher_worker WITH LOGIN;
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pgmq.meta WHERE queue_name = 'fetcher_tasks') THEN
        PERFORM pgmq.create('fetcher_tasks');
    END IF;
END $$;

GRANT CONNECT ON DATABASE history TO fetcher_worker;
GRANT USAGE ON SCHEMA public, pgmq TO fetcher_worker;
GRANT SELECT (id, status, updated_at), UPDATE (status, result, error, updated_at)
    ON fetcher_tasks TO fetcher_worker;
GRANT SELECT, INSERT, UPDATE, DELETE ON pgmq.q_fetcher_tasks, pgmq.a_fetcher_tasks TO fetcher_worker;
GRANT USAGE, SELECT ON SEQUENCE pgmq.q_fetcher_tasks_msg_id_seq TO fetcher_worker;
GRANT EXECUTE ON FUNCTION pgmq.read(TEXT, INTEGER, INTEGER, JSONB) TO fetcher_worker;
GRANT EXECUTE ON FUNCTION pgmq.delete(TEXT, BIGINT) TO fetcher_worker;
GRANT EXECUTE ON FUNCTION pgmq.archive(TEXT, BIGINT) TO fetcher_worker;

CREATE OR REPLACE FUNCTION cleanup_old_records(target_days INT DEFAULT 30)
RETURNS INTEGER AS $$
DECLARE deleted_count INTEGER;
BEGIN
    DELETE FROM history WHERE recorded_at < NOW() - make_interval(days => target_days);
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;
