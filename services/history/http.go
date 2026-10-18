package main

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/google/uuid"
)

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func accessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)

		remote := r.Header.Get("X-Real-IP")
		if remote == "" {
			remote = r.RemoteAddr
		}
		slog.Info("http request",
			"method", r.Method, "path", r.URL.Path, "status", rec.status,
			"duration", time.Since(start), "remote", remote)
	})
}

func GetHistory(w http.ResponseWriter, r *http.Request) {
	rows, err := db.Query(`SELECT name, sat_id, latitude, longitude, altitude, velocity, visibility, footprint, CAST(EXTRACT(EPOCH FROM timestamp) AS BIGINT), daynum, solar_lat, solar_lon, units FROM positions ORDER BY timestamp DESC LIMIT $1`, cfg.ResultLimit)
	if err != nil {
		slog.Error("history query failed", "err", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	var history []ISSData
	for rows.Next() {
		var d ISSData
		if err := rows.Scan(&d.Name, &d.ID, &d.Latitude, &d.Longitude, &d.Altitude, &d.Velocity, &d.Visibility, &d.Footprint, &d.Timestamp, &d.Daynum, &d.SolarLat, &d.SolarLon, &d.Units); err != nil {
			slog.Error("history row scan failed", "err", err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}
		history = append(history, d)
	}
	if err := rows.Err(); err != nil {
		slog.Error("history rows iteration failed", "err", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	if history == nil {
		history = []ISSData{}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(history)
}

func SettingsHandler(w http.ResponseWriter, r *http.Request) {
	var sessionID string
	if cookie, err := r.Cookie("session_id"); err == nil {
		if _, err := uuid.Parse(cookie.Value); err == nil {
			sessionID = cookie.Value
		}
	}
	if sessionID == "" {
		sessionID = uuid.New().String()
		http.SetCookie(w, &http.Cookie{
			Name:     "session_id",
			Value:    sessionID,
			Path:     "/",
			HttpOnly: true,
			MaxAge:   int(cfg.SessionTTL.Seconds()),
			SameSite: http.SameSiteLaxMode,
		})
	}

	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST")
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	if r.Method == http.MethodGet {
		theme, err := sessions.Theme(r.Context(), sessionID)
		if err != nil {
			slog.Warn("theme read failed, using default", "backend", cfg.SessionBackend, "err", err)
		}
		if theme == "" {
			theme = "light"
		}
		loc, err := sessions.Location(r.Context(), sessionID)
		if err != nil {
			slog.Warn("location read failed, ignored", "backend", cfg.SessionBackend, "err", err)
			loc = nil
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(struct {
			Theme    string    `json:"theme"`
			Location *Location `json:"location"`
		}{theme, loc})
		return
	}

	if r.Method == http.MethodPost {
		var req struct {
			Theme    *string   `json:"theme"`
			Location *Location `json:"location"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "Invalid JSON", http.StatusBadRequest)
			return
		}
		if req.Location != nil && !req.Location.valid() {
			http.Error(w, "Invalid location", http.StatusBadRequest)
			return
		}

		if req.Theme != nil {
			if err := sessions.SetTheme(r.Context(), sessionID, *req.Theme); err != nil {
				slog.Error("theme save failed", "backend", cfg.SessionBackend, "err", err)
				http.Error(w, "Internal Server Error", http.StatusInternalServerError)
				return
			}
		}
		if req.Location != nil {
			if err := sessions.SetLocation(r.Context(), sessionID, *req.Location); err != nil {
				slog.Error("location save failed", "backend", cfg.SessionBackend, "err", err)
				http.Error(w, "Internal Server Error", http.StatusInternalServerError)
				return
			}
		}

		w.WriteHeader(http.StatusOK)
	}
}
