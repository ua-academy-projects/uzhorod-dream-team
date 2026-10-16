-- +goose Up
CREATE EXTENSION IF NOT EXISTS pgmq;
CREATE EXTENSION IF NOT EXISTS hstore;
SELECT pgmq.create('kyiv_air_requests');
SELECT pgmq.create('kyiv_air_replies');
DROP TABLE sync_queue.requests;
DROP SCHEMA sync_queue;
TRUNCATE sessions;
ALTER TABLE sessions ALTER COLUMN preferences TYPE hstore USING hstore(ARRAY[]::text[]);

-- +goose Down
SELECT pgmq.drop_queue('kyiv_air_replies');
SELECT pgmq.drop_queue('kyiv_air_requests');
TRUNCATE sessions;
ALTER TABLE sessions ALTER COLUMN preferences TYPE jsonb USING '{}'::jsonb;
CREATE SCHEMA sync_queue;
CREATE TABLE sync_queue.requests (
 id TEXT PRIMARY KEY,
 request JSONB NOT NULL,
 deadline TIMESTAMPTZ NOT NULL,
 completed BOOLEAN NOT NULL DEFAULT FALSE,
 response JSONB
);
CREATE INDEX sync_requests_pending ON sync_queue.requests (deadline, id) WHERE NOT completed;
