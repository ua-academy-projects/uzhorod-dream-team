-- Keep the most recently collected snapshot for each city and weather time.
-- Run with psql --single-transaction. Archived duplicates remain recoverable.
LOCK TABLE weather_snapshots IN ACCESS EXCLUSIVE MODE;

CREATE TABLE IF NOT EXISTS weather_snapshots_duplicates AS
SELECT * FROM weather_snapshots WITH NO DATA;

CREATE TEMP TABLE duplicate_snapshot_ids ON COMMIT DROP AS
SELECT id FROM (
    SELECT id, row_number() OVER (
        PARTITION BY city, weather_time ORDER BY fetched_at DESC, id DESC
    ) AS position
    FROM weather_snapshots
) ranked WHERE position > 1;

INSERT INTO weather_snapshots_duplicates
SELECT snapshot.* FROM weather_snapshots snapshot
JOIN duplicate_snapshot_ids duplicate ON duplicate.id = snapshot.id;

DELETE FROM weather_snapshots
WHERE id IN (SELECT id FROM duplicate_snapshot_ids);

CREATE UNIQUE INDEX IF NOT EXISTS idx_weather_snapshots_city_weather_time
ON weather_snapshots (city, weather_time);
