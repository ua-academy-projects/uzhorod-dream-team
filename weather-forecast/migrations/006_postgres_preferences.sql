CREATE TABLE IF NOT EXISTS weather_preferences (
    session_id TEXT PRIMARY KEY,
    preferences public.hstore NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);

-- Preserve existing sessions and expiry times when upgrading preferences.
DO $$
BEGIN
    IF (SELECT atttypid = 'jsonb'::regtype FROM pg_attribute
        WHERE attrelid = 'weather_preferences'::regclass AND attname = 'preferences') THEN
        ALTER TABLE weather_preferences DROP CONSTRAINT IF EXISTS weather_preferences_preferences_check;
        ALTER TABLE weather_preferences ALTER COLUMN preferences TYPE public.hstore
            USING public.hstore('theme', preferences->>'theme');
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS weather_preferences_expires_at
    ON weather_preferences (expires_at);
