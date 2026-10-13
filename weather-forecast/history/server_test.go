package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

type memoryStore struct {
	snapshots    []Snapshot
	lastLimit    int
	chartCity    string
	chartSince   time.Time
	imported     []TemperaturePoint
	importedCity string
}

func (s *memoryStore) Insert(_ context.Context, snapshot Snapshot) (Snapshot, error) {
	for i, existing := range s.snapshots {
		if existing.City == snapshot.City && existing.WeatherTime.Equal(snapshot.WeatherTime) {
			snapshot.ID = existing.ID
			s.snapshots[i] = snapshot
			return snapshot, nil
		}
	}
	snapshot.ID = int64(len(s.snapshots) + 1)
	s.snapshots = append(s.snapshots, snapshot)
	return snapshot, nil
}
func (s *memoryStore) Latest(context.Context) (Snapshot, error) { return Snapshot{}, nil }
func (s *memoryStore) History(_ context.Context, limit int) ([]Snapshot, error) {
	s.lastLimit = limit
	return s.snapshots, nil
}
func (s *memoryStore) Ping(context.Context) error { return nil }

func (s *memoryStore) MissingTemperatureHours(context.Context, string, time.Time, time.Time) ([]time.Time, error) {
	return nil, nil
}

func (s *memoryStore) Temperature(_ context.Context, city string, since time.Time) ([]TemperaturePoint, error) {
	s.chartCity, s.chartSince = city, since
	return []TemperaturePoint{}, nil
}

func (s *memoryStore) SaveTemperature(_ context.Context, city string, points []TemperaturePoint) error {
	s.importedCity = city
	s.imported = points
	return nil
}

func TestTemperatureParameters(t *testing.T) {
	for _, query := range []string{"?city=Uzhhorod", "?city=Uzhhorod&period=24h", "?city=Uzhhorod&period=7d", "?city=Uzhhorod&period=30d"} {
		store := &memoryStore{}
		response := httptest.NewRecorder()
		newHandler(store, nil, "", nil).ServeHTTP(response, httptest.NewRequest("GET", "/api/temperature"+query, nil))
		if response.Code != 200 || response.Body.String() != "[]\n" || store.chartCity != "Uzhhorod" || store.chartSince.IsZero() {
			t.Fatalf("%s: %d %s", query, response.Code, response.Body.String())
		}
	}
	for _, query := range []string{"", "?city=", "?city=Uzhhorod&period=", "?city=Uzhhorod&period=1y", "?city=Uzhhorod&period=7d&period=24h", "?city=Lviv&city=Uzhhorod", "?city=%zz"} {
		response := httptest.NewRecorder()
		newHandler(&memoryStore{}, nil, "", nil).ServeHTTP(response, httptest.NewRequest("GET", "/api/temperature"+query, nil))
		if response.Code != 400 {
			t.Fatalf("%s: expected 400, got %d", query, response.Code)
		}
	}
}

func TestHistoryLimit(t *testing.T) {
	cases := []struct {
		query         string
		status, limit int
	}{
		{"", 200, 100}, {"?limit=1", 200, 1}, {"?limit=1000", 200, 1000},
		{"?limit=0", 400, 0}, {"?limit=-1", 400, 0}, {"?limit=1001", 400, 0},
		{"?limit=abc", 400, 0}, {"?limit=1.5", 400, 0}, {"?limit=", 400, 0},
		{"?limit=1&limit=2", 400, 0}, {"?limit=999999999999999999999", 400, 0},
		{"?limit=%zz", 400, 0},
	}
	for _, tc := range cases {
		t.Run(tc.query, func(t *testing.T) {
			store := &memoryStore{snapshots: []Snapshot{}}
			handler := newHandler(store, nil, "../ui", nil)
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/history"+tc.query, nil))
			if response.Code != tc.status {
				t.Fatalf("status=%d, want %d: %s", response.Code, tc.status, response.Body.String())
			}
			if store.lastLimit != tc.limit {
				t.Fatalf("database limit=%d, want %d", store.lastLimit, tc.limit)
			}
			if tc.status == 200 && response.Body.String() != "[]\n" {
				t.Fatalf("expected empty JSON array, got %s", response.Body.String())
			}
		})
	}
}

func TestHistoryWithoutUI(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://localhost/weather_history")
	t.Setenv("RABBITMQ_URL", "amqp://localhost/")
	t.Setenv("HISTORY_SERVE_UI", "false")
	t.Setenv("UI_DIR", "/missing-ui-directory")
	config, err := loadConfig()
	if err != nil || config.UIDir != "" {
		t.Fatalf("API-only config: %+v, error: %v", config, err)
	}
	handler := newHandler(&memoryStore{snapshots: []Snapshot{}}, nil, config.UIDir, nil)
	for path, status := range map[string]int{"/": 404, "/health": 200, "/api/history": 200} {
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		if response.Code != status {
			t.Fatalf("%s: status %d, want %d", path, response.Code, status)
		}
	}
}
