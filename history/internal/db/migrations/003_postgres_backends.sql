-- +goose Up
CREATE SCHEMA sync_queue;
CREATE TABLE sync_queue.requests (
 id TEXT PRIMARY KEY,
 request JSONB NOT NULL,
 deadline TIMESTAMPTZ NOT NULL,
 completed BOOLEAN NOT NULL DEFAULT FALSE,
 response JSONB
);
CREATE INDEX sync_requests_pending ON sync_queue.requests (deadline, id) WHERE NOT completed;
CREATE TABLE sessions (
 id TEXT PRIMARY KEY,
 preferences JSONB NOT NULL,
 expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX sessions_expiration ON sessions (expires_at);

-- +goose Down
DROP TABLE sessions;
DROP TABLE sync_queue.requests;
DROP SCHEMA sync_queue;
