-- Jobs also record processed request IDs and pending publications.
CREATE TABLE IF NOT EXISTS weather_jobs (
    request_id UUID PRIMARY KEY,
    type TEXT NOT NULL CHECK (type IN ('current_weather', 'temperature_history')),
    status TEXT NOT NULL CHECK (status IN ('queued', 'completed', 'failed')),
    request_payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    published_at TIMESTAMPTZ,
    processed_at TIMESTAMPTZ,
    error JSONB,
    result JSONB
);
CREATE UNIQUE INDEX IF NOT EXISTS weather_jobs_active_type
    ON weather_jobs (type) WHERE status = 'queued';
