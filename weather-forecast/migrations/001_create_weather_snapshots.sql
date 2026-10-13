-- Migration 001: Create the weather snapshots table
-- Table: weather_snapshots

CREATE TABLE IF NOT EXISTS weather_snapshots (
    id BIGSERIAL PRIMARY KEY,
    city VARCHAR(100) NOT NULL,
    latitude DOUBLE PRECISION NOT NULL,
    longitude DOUBLE PRECISION NOT NULL,
    temperature_c DOUBLE PRECISION NOT NULL,
    humidity_percent INTEGER NOT NULL,
    wind_speed_kmh DOUBLE PRECISION NOT NULL,
    weather_time TIMESTAMPTZ NOT NULL,
    fetched_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for finding the latest snapshot and sorting history
CREATE INDEX IF NOT EXISTS idx_weather_snapshots_fetched_at ON weather_snapshots (fetched_at DESC);
CREATE INDEX IF NOT EXISTS idx_weather_snapshots_weather_time ON weather_snapshots (weather_time DESC);
