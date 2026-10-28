-- BACKEND=postgres sessions on the hstore key-value extension: one key per value.
CREATE EXTENSION IF NOT EXISTS hstore;

-- Databases that ran the removed 004 have a json session table; sessions are disposable.
DROP TABLE IF EXISTS "session";

CREATE TABLE "session" (
    sid    text PRIMARY KEY,
    data   hstore NOT NULL,      -- theme => dark, cookie => {...}
    expire timestamptz NOT NULL
);

CREATE INDEX idx_session_expire ON "session" (expire);
