package worker

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"

	"fetcher/internal/openmeteo"
)

// Weather is what the worker needs from the Open-Meteo client (easy to fake in tests).
type Weather interface {
	FetchCurrent(ctx context.Context, loc openmeteo.Location) (openmeteo.Observation, error)
	FetchRecentHistory(ctx context.Context, loc openmeteo.Location, days int) ([]openmeteo.Observation, error)
}

const defaultHistoryDays = 7

// Request is the message the History service puts on the request queue.
//
//	{"type": "current", "location": {"name": "Berlin", "latitude": 52.52, "longitude": 13.41}}
//	{"type": "history", "location": {...}, "days": 30}
type Request struct {
	Type     string `json:"type"`
	Location struct {
		Name      string   `json:"name"`
		Latitude  *float64 `json:"latitude"`
		Longitude *float64 `json:"longitude"`
	} `json:"location"`
	Days *int `json:"days"`
}

// Error kinds in a failed Reply, so the caller can tell its own mistakes from upstream failures.
const (
	KindBadRequest = "bad_request"
	KindUpstream   = "upstream"
	KindInternal   = "internal"
)

// Reply is published back to the request's ReplyTo queue.
// Data is one observation for "current" and a list of observations for "history".
type Reply struct {
	OK    bool   `json:"ok"`
	Data  any    `json:"data,omitempty"`
	Error string `json:"error,omitempty"`
	Kind  string `json:"kind,omitempty"`
}

type badRequestError struct{ message string }

func (e *badRequestError) Error() string { return e.message }

// Handle turns one request body into a reply. It never fails: errors become a Reply with OK=false.
// No AMQP here, so it can be tested with a fake Weather.
func Handle(ctx context.Context, w Weather, body []byte) Reply {
	data, err := process(ctx, w, body)
	if err == nil {
		return Reply{OK: true, Data: data}
	}
	var bad *badRequestError
	var upstream *openmeteo.FetcherError
	switch {
	case errors.As(err, &bad):
		return Reply{Error: bad.Error(), Kind: KindBadRequest}
	case errors.As(err, &upstream):
		slog.Error(upstream.Error())
		return Reply{Error: upstream.Error(), Kind: KindUpstream}
	default:
		slog.Error("internal error", "error", err)
		return Reply{Error: "Internal error", Kind: KindInternal}
	}
}

func process(ctx context.Context, w Weather, body []byte) (any, error) {
	var req Request
	if err := json.Unmarshal(body, &req); err != nil {
		return nil, &badRequestError{"invalid request: " + err.Error()}
	}
	loc, err := req.location()
	if err != nil {
		return nil, err
	}
	switch req.Type {
	case "current":
		return w.FetchCurrent(ctx, loc)
	case "history":
		days := defaultHistoryDays
		if req.Days != nil {
			days = *req.Days
			if days < 1 || days > openmeteo.MaxHistoryDays {
				return nil, &badRequestError{fmt.Sprintf(`"days" must be an integer between 1 and %d`, openmeteo.MaxHistoryDays)}
			}
		}
		observations, err := w.FetchRecentHistory(ctx, loc, days)
		if err != nil {
			return nil, err
		}
		if observations == nil {
			observations = []openmeteo.Observation{} // JSON [] rather than null
		}
		return observations, nil
	default:
		return nil, &badRequestError{`"type" must be "current" or "history"`}
	}
}

func (r Request) location() (openmeteo.Location, error) {
	if r.Location.Name == "" {
		return openmeteo.Location{}, &badRequestError{`"location.name" is required`}
	}
	lat, err := coordinate(r.Location.Latitude, "latitude", 90)
	if err != nil {
		return openmeteo.Location{}, err
	}
	lon, err := coordinate(r.Location.Longitude, "longitude", 180)
	if err != nil {
		return openmeteo.Location{}, err
	}
	return openmeteo.Location{Name: r.Location.Name, Latitude: lat, Longitude: lon}, nil
}

func coordinate(v *float64, name string, limit float64) (float64, error) {
	if v == nil || math.IsNaN(*v) || math.IsInf(*v, 0) || math.Abs(*v) > limit {
		return 0, &badRequestError{fmt.Sprintf(`"location.%s" must be a number between -%g and %g`, name, limit, limit)}
	}
	return *v, nil
}
