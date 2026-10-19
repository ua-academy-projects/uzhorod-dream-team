package api

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"weather-history/internal/domain"
)

func parseLimit(query url.Values) (int, error) {
	values, exists := query["limit"]
	if !exists {
		return 100, nil
	}
	if len(values) != 1 || values[0] == "" {
		return 0, errors.New("limit must be a single integer between 1 and 1000")
	}
	for _, ch := range values[0] {
		if ch < '0' || ch > '9' {
			return 0, errors.New("limit must be an integer between 1 and 1000")
		}
	}
	limit, err := strconv.Atoi(values[0])
	if err != nil || limit < 1 || limit > 1000 {
		return 0, errors.New("limit must be an integer between 1 and 1000")
	}
	return limit, nil
}

func writeJSON(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("write response: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

type JobCollector interface {
	Collect(context.Context) (domain.Job, error)
	GetJob(context.Context, string) (domain.Job, error)
}

func NewHandler(store domain.Repository, collector JobCollector, uiDir string, preferences *PreferenceHandler) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/api/preferences", preferences)
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		if err := store.Ping(r.Context()); err != nil {
			log.Printf("health database: %v", err)
			writeError(w, http.StatusServiceUnavailable, "PostgreSQL is unavailable")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("POST /api/collect", func(w http.ResponseWriter, r *http.Request) {
		job, err := collector.Collect(r.Context())
		if err != nil {
			log.Print("manual collection could not be queued")
			var apiErr *domain.APIError
			if errors.As(err, &apiErr) {
				writeJSON(w, apiErr.Status, map[string]string{"error": apiErr.Message, "request_id": apiErr.RequestID})
			} else {
				writeError(w, http.StatusServiceUnavailable, "Could not queue the weather job in PostgreSQL")
			}
			return
		}
		log.Printf("manual collection queued request_id=%s", job.RequestID)
		writeJSON(w, http.StatusAccepted, map[string]string{"request_id": job.RequestID, "status": "queued"})
	})
	mux.HandleFunc("GET /api/jobs/{request_id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("request_id")
		if !domain.UUIDPattern.MatchString(id) {
			writeError(w, 400, "Invalid request_id")
			return
		}
		job, err := collector.GetJob(r.Context(), id)
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, 404, "Job not found")
			return
		}
		if err != nil {
			writeError(w, 503, "Could not read job status from PostgreSQL")
			return
		}
		writeJSON(w, 200, job)
	})
	mux.HandleFunc("GET /api/latest", func(w http.ResponseWriter, r *http.Request) {
		snapshot, err := store.Latest(r.Context())
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "History is empty")
			return
		}
		if err != nil {
			log.Printf("latest: %v", err)
			writeError(w, http.StatusServiceUnavailable, "Could not read data from PostgreSQL")
			return
		}
		writeJSON(w, http.StatusOK, snapshot)
	})
	mux.HandleFunc("GET /api/history", func(w http.ResponseWriter, r *http.Request) {
		query, err := url.ParseQuery(r.URL.RawQuery)
		if err != nil {
			writeError(w, http.StatusBadRequest, "Invalid query string")
			return
		}
		limit, err := parseLimit(query)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		snapshots, err := store.History(r.Context(), limit)
		if err != nil {
			log.Printf("history: %v", err)
			writeError(w, http.StatusServiceUnavailable, "Could not read data from PostgreSQL")
			return
		}
		writeJSON(w, http.StatusOK, snapshots)
	})
	mux.HandleFunc("GET /api/temperature", func(w http.ResponseWriter, r *http.Request) {
		query, err := url.ParseQuery(r.URL.RawQuery)
		if err != nil {
			writeError(w, http.StatusBadRequest, "Invalid query string")
			return
		}
		period := query.Get("period")
		if _, exists := query["period"]; !exists {
			period = "24h"
		}
		duration, valid := map[string]time.Duration{"24h": 24 * time.Hour, "7d": 7 * 24 * time.Hour, "30d": 30 * 24 * time.Hour}[period]
		city := query.Get("city")
		if !valid || len(query["period"]) > 1 || len(query["city"]) != 1 || strings.TrimSpace(city) == "" || len([]rune(city)) > 100 {
			writeError(w, http.StatusBadRequest, "Provide one city and period=24h, 7d, or 30d")
			return
		}
		points, err := store.Temperature(r.Context(), city, time.Now().UTC().Add(-duration))
		if err != nil {
			log.Printf("temperature chart: %v", err)
			writeError(w, http.StatusServiceUnavailable, "Could not load temperature history")
			return
		}
		writeJSON(w, http.StatusOK, points)
	})
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/jobs/") {
			w.Header().Set("Allow", "GET, HEAD")
			writeError(w, http.StatusMethodNotAllowed, "Use GET")
			return
		}
		switch r.URL.Path {
		case "/api/collect":
			w.Header().Set("Allow", "POST")
			writeError(w, http.StatusMethodNotAllowed, "Use POST")
			return
		case "/api/latest", "/api/history", "/api/temperature":
			w.Header().Set("Allow", "GET, HEAD")
			writeError(w, http.StatusMethodNotAllowed, "Use GET")
			return
		}
		writeError(w, http.StatusNotFound, "Unknown API endpoint")
	})
	files := http.FileServer(http.Dir(uiDir))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if uiDir == "" {
			writeError(w, http.StatusNotFound, "The UI is served by a separate Nginx server")
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			writeError(w, http.StatusMethodNotAllowed, "Use GET")
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		files.ServeHTTP(w, r)
	})
	return mux
}
