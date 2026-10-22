package main

// Messages between History and Fetcher in RabbitMQ (JSON).
// The format is the same as in fetcher/messages.py.

import (
	"context"
	"encoding/json"
	"log"
	"time"
)

// WeatherRecord is a single temperature measurement.
// The `json:"..."` tags tell what the fields are called in JSON.
type WeatherRecord struct {
	City         string    `json:"city"`
	TemperatureC float64   `json:"temperature_c"`
	ObservedAt   time.Time `json:"observed_at"` // Go parses RFC3339, e.g. 2026-10-04T21:45:00Z
	FetchedAt    time.Time `json:"fetched_at"`
}

// weatherRequest is what History puts into weather.requests.
type weatherRequest struct {
	RequestID   string `json:"request_id"`
	RequestedAt string `json:"requested_at"` // RFC3339 in UTC, e.g. 2026-10-11T15:00:00Z
}

// weatherResponse is what Fetcher puts into weather.responses.
// If OK is true, Record has the measurement; otherwise Error says what went wrong.
type weatherResponse struct {
	RequestID string         `json:"request_id"`
	OK        bool           `json:"ok"`
	Record    *WeatherRecord `json:"record"`
	Error     string         `json:"error"`
}

// newRequest returns a request as JSON.
func newRequest(requestID string, now time.Time) ([]byte, error) {
	return json.Marshal(weatherRequest{
		RequestID:   requestID,
		RequestedAt: now.UTC().Format(time.RFC3339),
	})
}

// responseAction says what to tell RabbitMQ after a response was handled.
type responseAction int

const (
	ackResponse    responseAction = iota // done: saved, a duplicate, or Fetcher's error logged
	rejectResponse                       // broken message: RabbitMQ removes it, repeating will not help
	retryResponse                        // temporary error (database): RabbitMQ delivers it again
)

// handleResponse handles one response from Fetcher and says what to do with the message.
// save writes a record to the database (in tests it is a fake function).
func handleResponse(
	ctx context.Context,
	body []byte,
	save func(context.Context, WeatherRecord) (bool, error),
) responseAction {
	var response weatherResponse
	if err := json.Unmarshal(body, &response); err != nil {
		log.Printf("ПОМИЛКА: некоректна відповідь від fetcher відкинута: %v", err)
		return rejectResponse
	}
	if response.RequestID == "" {
		log.Printf("ПОМИЛКА: відповідь від fetcher без request_id відкинута")
		return rejectResponse
	}

	if !response.OK {
		log.Printf("ПОМИЛКА отримання погоди (запит %s): %s — нічого не записано",
			response.RequestID, response.Error)
		return ackResponse
	}

	record := response.Record
	if record == nil || record.City == "" || record.ObservedAt.IsZero() || record.FetchedAt.IsZero() {
		log.Printf("ПОМИЛКА: fetcher повернув неповні дані (запит %s) — нічого не записано",
			response.RequestID)
		return rejectResponse
	}

	inserted, err := save(ctx, *record)
	if err != nil {
		log.Printf("ПОМИЛКА збереження (запит %s): %v — спробуємо ще раз", response.RequestID, err)
		return retryResponse
	}

	observed := record.ObservedAt.UTC().Format(time.RFC3339)
	if inserted {
		log.Printf("збережено: %s %.1f °C (виміряно %s)", record.City, record.TemperatureC, observed)
	} else {
		log.Printf("вже є в базі: %s (виміряно %s) — дублікат пропущено", record.City, observed)
	}
	return ackResponse
}
