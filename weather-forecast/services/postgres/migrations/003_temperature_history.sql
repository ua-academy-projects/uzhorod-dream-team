-- Hourly provider history for the chart, separate from manual weather snapshots.
CREATE TABLE IF NOT EXISTS temperature_history (
    city VARCHAR(100) NOT NULL,
    weather_time TIMESTAMPTZ NOT NULL,
    temperature_c DOUBLE PRECISION NOT NULL,
    fetched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (city, weather_time)
);
