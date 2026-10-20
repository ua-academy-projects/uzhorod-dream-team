CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS pgmq;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pgmq.meta WHERE queue_name = 'fetcher_tasks') THEN
        PERFORM pgmq.create('fetcher_tasks');
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'fetcher_worker'
    ) THEN
        CREATE ROLE fetcher_worker LOGIN;
    ELSE
        ALTER ROLE fetcher_worker WITH LOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA pgmq TO fetcher_worker;
GRANT SELECT, INSERT, UPDATE, DELETE
    ON TABLE pgmq.q_fetcher_tasks, pgmq.a_fetcher_tasks TO fetcher_worker;
GRANT USAGE, SELECT ON SEQUENCE pgmq.q_fetcher_tasks_msg_id_seq TO fetcher_worker;
GRANT EXECUTE ON FUNCTION pgmq.read(TEXT, INTEGER, INTEGER, JSONB) TO fetcher_worker;
GRANT EXECUTE ON FUNCTION pgmq.delete(TEXT, BIGINT) TO fetcher_worker;
GRANT EXECUTE ON FUNCTION pgmq.archive(TEXT, BIGINT) TO fetcher_worker;

-- Password is configured separately by postgres.sh.

CREATE TABLE IF NOT EXISTS user_preferences (
    session_id TEXT PRIMARY KEY,
    preferences HSTORE NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

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
ALTER TABLE fetcher_tasks ADD COLUMN IF NOT EXISTS queue_enqueued BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_fetcher_tasks_pending
    ON fetcher_tasks (id)
    WHERE status = 'pending';

GRANT CONNECT ON DATABASE history TO fetcher_worker;
GRANT USAGE ON SCHEMA public TO fetcher_worker;

GRANT SELECT (id, status, updated_at)
    ON TABLE fetcher_tasks TO fetcher_worker;

GRANT UPDATE (status, result, error, updated_at)
    ON TABLE fetcher_tasks TO fetcher_worker;

WITH pending AS (
    UPDATE fetcher_tasks SET queue_enqueued=TRUE, status='pending', updated_at=NOW()
    WHERE queue_enqueued=FALSE AND status IN ('pending','processing')
    RETURNING id
)
SELECT pgmq.send('fetcher_tasks', jsonb_build_object('task_id', id)) FROM pending;
    
