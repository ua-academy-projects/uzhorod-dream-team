-- Table with temperature history.
-- IF NOT EXISTS: the file can be run again — no error, and data is not erased.
CREATE TABLE IF NOT EXISTS weather_records (
    -- Record number; PostgreSQL increments it automatically.
    id            BIGSERIAL PRIMARY KEY,

    -- City name, for example 'Lviv'.
    city          TEXT NOT NULL,

    -- Temperature in degrees Celsius: up to 4 digits, 1 after the decimal point (-99.9 ... 999.9).
    temperature_c NUMERIC(4, 1) NOT NULL,

    -- When Open-Meteo measured the temperature (time from the API).
    -- TIMESTAMPTZ stores a moment in time in UTC.
    observed_at   TIMESTAMPTZ NOT NULL,

    -- When our service received this data.
    fetched_at    TIMESTAMPTZ NOT NULL,

    -- Do not allow two records for the same city with the same measurement time.
    CONSTRAINT weather_records_city_observed_at_key UNIQUE (city, observed_at)
);

-- The table below is used only in app_mode postgres (see weather-vm.yml and README).
-- In mode rabbitmq it stays empty. The queues of mode postgres are not tables of this
-- file: they are queues of the extension pgmq (created by provision/db-mode.sh).

-- hstore: the type "key => value" of a PostgreSQL extension, like a value in Redis.
-- It comes with PostgreSQL and is "trusted", so the role of the app may turn it on.
-- Here, not only in provision/db-extensions.sh: provision/db.sh applies this file earlier.
CREATE EXTENSION IF NOT EXISTS hstore;

-- UI settings (theme and language) by the session id from the browser cookie, like in Redis.
CREATE TABLE IF NOT EXISTS user_settings (
    session_id    TEXT PRIMARY KEY,
    -- For example 'theme=>dark, lang=>uk'.
    settings      hstore NOT NULL,
    -- 30 days after the last visit the settings are not used.
    -- The job of pg_cron removes them (see provision/db-mode.sh), like the TTL of Redis.
    expires_at    TIMESTAMPTZ NOT NULL
);
