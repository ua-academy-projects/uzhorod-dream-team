package postgres

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"weather-history/internal/domain"
)

// Persisted hours are the checkpoint, including gaps after failed requests.
func (s *Store) MissingTemperatureHours(ctx context.Context, city string, start, end time.Time) ([]time.Time, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx, `SELECT hour FROM generate_series($2::timestamptz, $3::timestamptz, interval '1 hour') AS hour
 WHERE NOT EXISTS (SELECT 1 FROM temperature_history WHERE city = $1 AND weather_time = hour)
 ORDER BY hour`, city, start, end)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var hours []time.Time
	for rows.Next() {
		var hour time.Time
		if err := rows.Scan(&hour); err != nil {
			return nil, err
		}
		hours = append(hours, hour.UTC())
	}
	return hours, rows.Err()
}

// Imported hourly values fill gaps; collected snapshots provide a fallback.
func (s *Store) Temperature(ctx context.Context, city string, since time.Time) ([]domain.TemperaturePoint, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx, `WITH collected AS (SELECT
  date_trunc('hour', weather_time AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS hour,
  avg(temperature_c) AS temperature_c
  FROM weather_snapshots
  WHERE city = $1 AND weather_time >= $2 AND weather_time <= NOW()
  GROUP BY 1), imported AS (
    SELECT weather_time, temperature_c FROM temperature_history
    WHERE city = $1 AND weather_time >= date_trunc('hour', $2::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
      AND weather_time <= NOW()
  )
  SELECT COALESCE(imported.weather_time, collected.hour),
         COALESCE(imported.temperature_c, collected.temperature_c)
  FROM imported FULL JOIN collected ON imported.weather_time = collected.hour
  ORDER BY 1`, city, since)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	points := make([]domain.TemperaturePoint, 0)
	for rows.Next() {
		var point domain.TemperaturePoint
		if err := rows.Scan(&point.WeatherTime, &point.TemperatureC); err != nil {
			return nil, err
		}
		point.WeatherTime = point.WeatherTime.UTC()
		points = append(points, point)
	}
	return points, rows.Err()
}

func (s *Store) SaveTemperature(ctx context.Context, city string, points []domain.TemperaturePoint) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err := saveTemperature(ctx, tx, city, points); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func saveTemperature(ctx context.Context, tx pgx.Tx, city string, points []domain.TemperaturePoint) error {
	batch := &pgx.Batch{}
	for _, point := range points {
		batch.Queue(`INSERT INTO temperature_history (city, weather_time, temperature_c)
 VALUES ($1, $2, $3) ON CONFLICT (city, weather_time) DO UPDATE
 SET temperature_c = EXCLUDED.temperature_c, fetched_at = NOW()`, city, point.WeatherTime, point.TemperatureC)
	}
	results := tx.SendBatch(ctx, batch)
	if err := results.Close(); err != nil {
		return err
	}
	return nil
}
