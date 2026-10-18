package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"sync"
	"time"
)

const (
	minPassRadiusKm = 100
	maxPassRadiusKm = 3000
	recordedPassGap = 10 * time.Minute
	orbitRefitAfter = time.Minute
)

type Location struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	RadiusKm  float64 `json:"radius_km"`
}

func (l Location) valid() bool {
	return l.Latitude >= -90 && l.Latitude <= 90 &&
		l.Longitude >= -180 && l.Longitude <= 180 &&
		l.RadiusKm >= minPassRadiusKm && l.RadiusKm <= maxPassRadiusKm
}

type passInfo struct {
	Start           int64        `json:"start"`
	End             int64        `json:"end"`
	Closest         int64        `json:"closest"`
	MinDistanceKm   float64      `json:"min_distance_km"`
	MaxElevationDeg float64      `json:"max_elevation_deg"`
	Visibility      string       `json:"visibility,omitempty"`
	Track           [][2]float64 `json:"track"`
}

type orbitSummary struct {
	Points         int     `json:"points"`
	SpanHours      float64 `json:"span_hours"`
	PeriodMinutes  float64 `json:"period_minutes"`
	InclinationDeg float64 `json:"inclination_deg"`
	LastObserved   int64   `json:"last_observed"`
}

type passesResponse struct {
	Now         int64         `json:"now"`
	OverheadNow bool          `json:"overhead_now"`
	Last        *passInfo     `json:"last"`
	Next        *passInfo     `json:"next"`
	Model       *orbitSummary `json:"model"`
	ModelError  string        `json:"model_error,omitempty"`
}

func PassesHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	loc, ok := parseLocation(r.URL.Query())
	if !ok {
		http.Error(w, fmt.Sprintf("lat, lon and radius_km (%d-%d) are required", minPassRadiusKm, maxPassRadiusKm), http.StatusBadRequest)
		return
	}

	resp := passesResponse{Now: time.Now().Unix()}
	last, err := lastRecordedPass(r.Context(), loc)
	if err != nil {
		slog.Error("recorded pass query failed", "err", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	resp.Last = last

	model, err := currentOrbit(r.Context())
	switch {
	case errors.Is(err, errNotEnoughData):
		resp.ModelError = err.Error()
	case err != nil:
		slog.Error("orbit model unavailable", "err", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	default:
		resp.Model = model.summary()
		resp.OverheadNow, resp.Next = model.nextPass(float64(resp.Now), loc)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func parseLocation(q url.Values) (Location, bool) {
	var values [3]float64
	for i, key := range []string{"lat", "lon", "radius_km"} {
		v, err := strconv.ParseFloat(q.Get(key), 64)
		if err != nil {
			return Location{}, false
		}
		values[i] = v
	}
	loc := Location{Latitude: values[0], Longitude: values[1], RadiusKm: values[2]}
	return loc, loc.valid()
}

func lastRecordedPass(ctx context.Context, loc Location) (*passInfo, error) {
	band := loc.RadiusKm / (earthRadiusKm * math.Pi / 180)
	rows, err := db.QueryContext(ctx, `SELECT epoch, latitude, longitude, altitude, visibility, distance_km FROM (
			SELECT CAST(EXTRACT(EPOCH FROM timestamp) AS BIGINT) AS epoch, latitude, longitude, altitude, visibility,
				2 * $5::float8 * asin(least(1, sqrt(
					power(sin(radians(latitude - $1::float8) / 2), 2) +
					cos(radians($1::float8)) * cos(radians(latitude)) * power(sin(radians(longitude - $2::float8) / 2), 2)
				))) AS distance_km
			FROM positions
			WHERE latitude BETWEEN $1::float8 - $4::float8 AND $1::float8 + $4::float8
		) nearby
		WHERE distance_km <= $3::float8
		ORDER BY epoch DESC
		LIMIT 200`,
		loc.Latitude, loc.Longitude, loc.RadiusKm, band, earthRadiusKm)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var p *passInfo
	var earliest int64
	for rows.Next() {
		var epoch int64
		var lat, lon, alt, distance float64
		var visibility string
		if err := rows.Scan(&epoch, &lat, &lon, &alt, &visibility, &distance); err != nil {
			return nil, err
		}
		if p == nil {
			p = &passInfo{End: epoch, MinDistanceKm: math.Inf(1)}
		} else if time.Duration(earliest-epoch)*time.Second > recordedPassGap {
			break
		}
		earliest = epoch
		p.Track = append(p.Track, [2]float64{lat, lon})
		if distance < p.MinDistanceKm {
			p.MinDistanceKm, p.Closest, p.Visibility = distance, epoch, visibility
			p.MaxElevationDeg = elevationDeg(distance, alt)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if p == nil {
		return nil, nil
	}
	p.Start = earliest
	for i, j := 0, len(p.Track)-1; i < j; i, j = i+1, j-1 {
		p.Track[i], p.Track[j] = p.Track[j], p.Track[i]
	}
	return p, nil
}

var orbitCache struct {
	sync.Mutex
	model    *orbitModel
	err      error
	fittedAt time.Time
}

func currentOrbit(ctx context.Context) (*orbitModel, error) {
	orbitCache.Lock()
	defer orbitCache.Unlock()
	if !orbitCache.fittedAt.IsZero() && time.Since(orbitCache.fittedAt) < orbitRefitAfter {
		return orbitCache.model, orbitCache.err
	}

	obs, err := loadObservations(ctx)
	if err != nil {
		return nil, err
	}
	model, err := fitOrbit(obs)
	orbitCache.model, orbitCache.err, orbitCache.fittedAt = model, err, time.Now()
	if err != nil {
		slog.Warn("orbit model not fitted", "err", err)
		return nil, err
	}
	s := model.summary()
	slog.Info("orbit model fitted",
		"points", s.Points, "span_hours", fmt.Sprintf("%.1f", s.SpanHours),
		"period_min", fmt.Sprintf("%.3f", s.PeriodMinutes), "inclination", fmt.Sprintf("%.3f", s.InclinationDeg))
	return model, nil
}

func loadObservations(ctx context.Context) ([]observation, error) {
	rows, err := db.QueryContext(ctx, `SELECT CAST(EXTRACT(EPOCH FROM timestamp) AS FLOAT8), latitude, longitude, altitude
		FROM positions
		WHERE timestamp > (SELECT max(timestamp) FROM positions) - $1::interval
		ORDER BY timestamp`,
		fmt.Sprintf("%d seconds", int64(orbitFitWindow.Seconds())))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var obs []observation
	for rows.Next() {
		var t, lat, lon, alt float64
		if err := rows.Scan(&t, &lat, &lon, &alt); err != nil {
			return nil, err
		}
		obs = append(obs, newObservation(t, lat, lon, alt))
	}
	return obs, rows.Err()
}
