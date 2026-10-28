-- BACKEND=postgres queue on the pgmq extension.

-- Databases that ran the removed 002 still have its hand-made queue.
DROP TABLE IF EXISTS queue_messages;
DROP FUNCTION IF EXISTS queue_notify();

CREATE EXTENSION IF NOT EXISTS pgmq;
SELECT pgmq.create('price_requests');
SELECT pgmq.create('price_results');

-- pgmq has no dedup: one quote request per pair while it waits; history requests (days) pass.
CREATE UNIQUE INDEX IF NOT EXISTS uq_pending_quote
    ON pgmq.q_price_requests ((message->>'coin'), (message->>'vs'))
    WHERE message->>'days' IS NULL;

-- The fetcher's login: reads requests, writes results, nothing else.
-- Its password is set by provision-db.sh.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'queue_worker') THEN
        CREATE ROLE queue_worker LOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA pgmq TO queue_worker;
GRANT SELECT ON pgmq.meta TO queue_worker;
GRANT SELECT, UPDATE, DELETE ON pgmq.q_price_requests TO queue_worker;
GRANT SELECT, INSERT ON pgmq.q_price_results TO queue_worker;
