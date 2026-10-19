package api

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"weather-history/internal/config"
	"weather-history/internal/domain"
	"weather-history/internal/testutil"
)

func TestTemperatureParameters(t *testing.T) {
	for _, query := range []string{"?city=Uzhhorod", "?city=Uzhhorod&period=24h", "?city=Uzhhorod&period=7d", "?city=Uzhhorod&period=30d"} {
		store := &testutil.MemoryStore{}
		response := httptest.NewRecorder()
		NewHandler(store, nil, "", nil).ServeHTTP(response, httptest.NewRequest("GET", "/api/temperature"+query, nil))
		if response.Code != 200 || response.Body.String() != "[]\n" || store.ChartCity != "Uzhhorod" || store.ChartSince.IsZero() {
			t.Fatalf("%s: %d %s", query, response.Code, response.Body.String())
		}
	}
	for _, query := range []string{"", "?city=", "?city=Uzhhorod&period=", "?city=Uzhhorod&period=1y", "?city=Uzhhorod&period=7d&period=24h", "?city=Lviv&city=Uzhhorod", "?city=%zz"} {
		response := httptest.NewRecorder()
		NewHandler(&testutil.MemoryStore{}, nil, "", nil).ServeHTTP(response, httptest.NewRequest("GET", "/api/temperature"+query, nil))
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
			store := &testutil.MemoryStore{Snapshots: []domain.Snapshot{}}
			handler := NewHandler(store, nil, "../ui", nil)
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/history"+tc.query, nil))
			if response.Code != tc.status {
				t.Fatalf("status=%d, want %d: %s", response.Code, tc.status, response.Body.String())
			}
			if store.LastLimit != tc.limit {
				t.Fatalf("database limit=%d, want %d", store.LastLimit, tc.limit)
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
	cfg, err := config.Load()
	if err != nil || cfg.UIDir != "" {
		t.Fatalf("API-only config: %+v, error: %v", cfg, err)
	}
	handler := NewHandler(&testutil.MemoryStore{Snapshots: []domain.Snapshot{}}, nil, cfg.UIDir, nil)
	for path, status := range map[string]int{"/": 404, "/health": 200, "/api/history": 200} {
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		if response.Code != status {
			t.Fatalf("%s: status %d, want %d", path, response.Code, status)
		}
	}
}
