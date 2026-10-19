package postgres

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"weather-history/internal/domain"
)

const Columns = "id, city, latitude, longitude, temperature_c, humidity_percent, wind_speed_kmh, weather_time, fetched_at"

func scanSnapshot(row pgx.Row) (domain.Snapshot, error) {
	var s domain.Snapshot
	err := row.Scan(&s.ID, &s.City, &s.Latitude, &s.Longitude, &s.TemperatureC,
		&s.HumidityPercent, &s.WindSpeedKMH, &s.WeatherTime, &s.FetchedAt)
	s.WeatherTime = s.WeatherTime.UTC()
	s.FetchedAt = s.FetchedAt.UTC()
	return s, err
}

func (s *Store) Insert(ctx context.Context, snapshot domain.Snapshot) (domain.Snapshot, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return insertSnapshot(ctx, s.pool, snapshot)
}

// Both normal calls and job-result transactions use the same SQL.
func insertSnapshot(ctx context.Context, db interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}, snapshot domain.Snapshot) (domain.Snapshot, error) {
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
  RETURNING `+Columns,
		snapshot.City, snapshot.Latitude, snapshot.Longitude, snapshot.TemperatureC,
		snapshot.HumidityPercent, snapshot.WindSpeedKMH, snapshot.WeatherTime, snapshot.FetchedAt))
}

func (s *Store) Latest(ctx context.Context) (domain.Snapshot, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return scanSnapshot(s.pool.QueryRow(ctx, "SELECT "+Columns+" FROM weather_snapshots ORDER BY fetched_at DESC, id DESC LIMIT 1"))
}

func (s *Store) History(ctx context.Context, limit int) ([]domain.Snapshot, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx, "SELECT "+Columns+" FROM weather_snapshots ORDER BY fetched_at DESC, id DESC LIMIT $1", limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	snapshots := make([]domain.Snapshot, 0)
	for rows.Next() {
		snapshot, err := scanSnapshot(rows)
		if err != nil {
			return nil, err
		}
		snapshots = append(snapshots, snapshot)
	}
	return snapshots, rows.Err()
}
