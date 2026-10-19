package testutil

import (
	"context"
	"time"

	"weather-history/internal/domain"
)

type MemoryStore struct {
	Snapshots    []domain.Snapshot
	LastLimit    int
	ChartCity    string
	ChartSince   time.Time
	Imported     []domain.TemperaturePoint
	ImportedCity string
}

func (s *MemoryStore) Insert(_ context.Context, snapshot domain.Snapshot) (domain.Snapshot, error) {
	for i, existing := range s.Snapshots {
		if existing.City == snapshot.City && existing.WeatherTime.Equal(snapshot.WeatherTime) {
			snapshot.ID = existing.ID
			s.Snapshots[i] = snapshot
			return snapshot, nil
		}
	}
	snapshot.ID = int64(len(s.Snapshots) + 1)
	s.Snapshots = append(s.Snapshots, snapshot)
	return snapshot, nil
}

func (s *MemoryStore) Latest(context.Context) (domain.Snapshot, error) { return domain.Snapshot{}, nil }

func (s *MemoryStore) History(_ context.Context, limit int) ([]domain.Snapshot, error) {
	s.LastLimit = limit
	return s.Snapshots, nil
}

func (s *MemoryStore) Ping(context.Context) error { return nil }

func (s *MemoryStore) MissingTemperatureHours(context.Context, string, time.Time, time.Time) ([]time.Time, error) {
	return nil, nil
}

func (s *MemoryStore) Temperature(_ context.Context, city string, since time.Time) ([]domain.TemperaturePoint, error) {
	s.ChartCity, s.ChartSince = city, since
	return []domain.TemperaturePoint{}, nil
}

func (s *MemoryStore) SaveTemperature(_ context.Context, city string, points []domain.TemperaturePoint) error {
	s.ImportedCity = city
	s.Imported = points
	return nil
}
