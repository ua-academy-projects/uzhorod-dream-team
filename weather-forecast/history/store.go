package main

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// A small interface allows testing collection without a real database.
type Repository interface {
	Insert(context.Context, Snapshot) (Snapshot, error)
	Latest(context.Context) (Snapshot, error)
	History(context.Context, int) ([]Snapshot, error)
	Temperature(context.Context, string, time.Time) ([]TemperaturePoint, error)
	SaveTemperature(context.Context, string, []TemperaturePoint) error
	MissingTemperatureHours(context.Context, string, time.Time, time.Time) ([]time.Time, error)
	Ping(context.Context) error
}

type Store struct {
	pool    *pgxpool.Pool
	backend string
}

func (s *Store) queueBackend() string {
	if s.backend == "" {
		return backendRabbitMQRedis
	}
	return s.backend
}

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

type TemperaturePoint struct {
	WeatherTime  time.Time `json:"weather_time"`
	TemperatureC float64   `json:"temperature_c"`
}

const columns = "id, city, latitude, longitude, temperature_c, humidity_percent, wind_speed_kmh, weather_time, fetched_at"

func scanSnapshot(row pgx.Row) (Snapshot, error) {
	var s Snapshot
	err := row.Scan(&s.ID, &s.City, &s.Latitude, &s.Longitude, &s.TemperatureC,
		&s.HumidityPercent, &s.WindSpeedKMH, &s.WeatherTime, &s.FetchedAt)
	s.WeatherTime = s.WeatherTime.UTC()
	s.FetchedAt = s.FetchedAt.UTC()
	return s, err
}

func (s *Store) Insert(ctx context.Context, snapshot Snapshot) (Snapshot, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return insertSnapshot(ctx, s.pool, snapshot)
}

// Both normal calls and job-result transactions use the same SQL.
func insertSnapshot(ctx context.Context, db interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}, snapshot Snapshot) (Snapshot, error) {
	return scanSnapshot(db.QueryRow(ctx, `INSERT INTO weather_snapshots
  (city, latitude, longitude, temperature_c, humidity_percent, wind_speed_kmh, weather_time, fetched_at)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
  ON CONFLICT (city, weather_time) DO UPDATE SET
    latitude = EXCLUDED.latitude,
    longitude = EXCLUDED.longitude,
    temperature_c = EXCLUDED.temperature_c,
    humidity_percent = EXCLUDED.humidity_percent,
    wind_speed_kmh = EXCLUDED.wind_speed_kmh,
    fetched_at = EXCLUDED.fetched_at
  RETURNING `+columns,
		snapshot.City, snapshot.Latitude, snapshot.Longitude, snapshot.TemperatureC,
		snapshot.HumidityPercent, snapshot.WindSpeedKMH, snapshot.WeatherTime, snapshot.FetchedAt))
}

func (s *Store) Latest(ctx context.Context) (Snapshot, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return scanSnapshot(s.pool.QueryRow(ctx, "SELECT "+columns+" FROM weather_snapshots ORDER BY fetched_at DESC, id DESC LIMIT 1"))
}

func (s *Store) History(ctx context.Context, limit int) ([]Snapshot, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx, "SELECT "+columns+" FROM weather_snapshots ORDER BY fetched_at DESC, id DESC LIMIT $1", limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	snapshots := make([]Snapshot, 0)
	for rows.Next() {
		snapshot, err := scanSnapshot(rows)
		if err != nil {
			return nil, err
		}
		snapshots = append(snapshots, snapshot)
	}
	return snapshots, rows.Err()
}

func (s *Store) Ping(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return s.pool.Ping(ctx)
}

// Imported hourly values fill gaps; collected snapshots provide a fallback.
func (s *Store) Temperature(ctx context.Context, city string, since time.Time) ([]TemperaturePoint, error) {
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
	points := make([]TemperaturePoint, 0)
	for rows.Next() {
		var point TemperaturePoint
		if err := rows.Scan(&point.WeatherTime, &point.TemperatureC); err != nil {
			return nil, err
		}
		point.WeatherTime = point.WeatherTime.UTC()
		points = append(points, point)
	}
	return points, rows.Err()
}

func (s *Store) SaveTemperature(ctx context.Context, city string, points []TemperaturePoint) error {
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

func saveTemperature(ctx context.Context, tx pgx.Tx, city string, points []TemperaturePoint) error {
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
