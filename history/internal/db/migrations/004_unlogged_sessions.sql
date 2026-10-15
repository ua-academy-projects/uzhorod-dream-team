-- +goose Up
ALTER TABLE sessions SET UNLOGGED;

-- +goose Down
ALTER TABLE sessions SET LOGGED;
