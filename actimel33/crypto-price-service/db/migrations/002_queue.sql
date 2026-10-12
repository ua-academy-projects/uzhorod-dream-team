CREATE TABLE IF NOT EXISTS queue_messages (
    id           BIGSERIAL PRIMARY KEY,
    topic        TEXT NOT NULL CHECK (topic IN ('price:requests', 'price:results')),
    payload      JSONB NOT NULL,
    -- A taken message is leased: invisible until this moment, then retried.
    available_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    attempts     INT NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_queue_ready ON queue_messages (topic, available_at, id);

-- One quote request per pair in flight; history requests (with days) are not deduplicated.
CREATE UNIQUE INDEX IF NOT EXISTS uq_queue_pending_quote
    ON queue_messages ((payload->>'coin'), (payload->>'vs'))
    WHERE topic = 'price:requests' AND payload->>'days' IS NULL;

-- Wakes consumers at once instead of waiting for the next poll.
CREATE OR REPLACE FUNCTION queue_notify() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify(NEW.topic, '');
    RETURN NEW;
END $$;

CREATE OR REPLACE TRIGGER queue_notify AFTER INSERT ON queue_messages
    FOR EACH ROW EXECUTE FUNCTION queue_notify();

-- The fetcher's login: the queue and nothing else. Its password is set by provision-db.sh.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'queue_worker') THEN
        CREATE ROLE queue_worker LOGIN;
    END IF;
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON queue_messages TO queue_worker;
GRANT USAGE ON SEQUENCE queue_messages_id_seq TO queue_worker;