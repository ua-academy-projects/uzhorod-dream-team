-- +goose Up
ALTER TABLE locations ADD COLUMN last_sync_time TIMESTAMPTZ;

-- +goose Down
ALTER TABLE locations DROP COLUMN last_sync_time;
