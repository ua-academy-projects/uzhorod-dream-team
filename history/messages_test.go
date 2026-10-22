package main

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"
)

const goodResponse = `{"request_id": "abc-1", "ok": true, "record": {
	"city": "Lviv", "temperature_c": 11.6,
	"observed_at": "2026-10-11T17:45:00Z", "fetched_at": "2026-10-11T17:56:18Z"}}`

// saveMustNotBeCalled is a fake save for cases where nothing must be written.
func saveMustNotBeCalled(t *testing.T) func(context.Context, WeatherRecord) (bool, error) {
	return func(context.Context, WeatherRecord) (bool, error) {
		t.Fatal("запис у базу не мав відбутися")
		return false, nil
	}
}

func TestNewRequestHasIDAndUTCTime(t *testing.T) {
	kyiv := time.FixedZone("Kyiv", 3*60*60)
	body, err := newRequest("abc-1", time.Date(2026, 10, 11, 18, 0, 0, 123, kyiv))
	if err != nil {
		t.Fatal(err)
	}

	var got weatherRequest
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("не вдалося прочитати JSON: %v", err)
	}
	want := weatherRequest{RequestID: "abc-1", RequestedAt: "2026-10-11T15:00:00Z"}
	if got != want {
		t.Fatalf("запит = %#v, очікувався %#v", got, want)
	}
}

func TestHandleResponseSavesRecord(t *testing.T) {
	var saved WeatherRecord
	save := func(_ context.Context, record WeatherRecord) (bool, error) {
		saved = record
		return true, nil
	}

	action := handleResponse(context.Background(), []byte(goodResponse), save)

	if action != ackResponse {
		t.Fatalf("дія = %d, очікувався ack", action)
	}
	want := WeatherRecord{
		City:         "Lviv",
		TemperatureC: 11.6,
		ObservedAt:   time.Date(2026, 10, 11, 17, 45, 0, 0, time.UTC),
		FetchedAt:    time.Date(2026, 10, 11, 17, 56, 18, 0, time.UTC),
	}
	if !saved.ObservedAt.Equal(want.ObservedAt) || !saved.FetchedAt.Equal(want.FetchedAt) ||
		saved.City != want.City || saved.TemperatureC != want.TemperatureC {
		t.Fatalf("збережено %#v, очікувалося %#v", saved, want)
	}
}

func TestHandleResponseDuplicateIsAcknowledged(t *testing.T) {
	save := func(context.Context, WeatherRecord) (bool, error) { return false, nil }

	if action := handleResponse(context.Background(), []byte(goodResponse), save); action != ackResponse {
		t.Fatalf("дія = %d, очікувався ack", action)
	}
}

func TestHandleResponseFetcherErrorSavesNothing(t *testing.T) {
	body := []byte(`{"request_id": "abc-1", "ok": false, "error": "Open-Meteo timeout"}`)

	if action := handleResponse(context.Background(), body, saveMustNotBeCalled(t)); action != ackResponse {
		t.Fatalf("дія = %d, очікувався ack", action)
	}
}

func TestHandleResponseRejectsBrokenMessages(t *testing.T) {
	bodies := map[string]string{
		"не JSON":         `hello`,
		"без request_id":  `{"ok": true, "record": {"city": "Lviv"}}`,
		"без record":      `{"request_id": "abc-1", "ok": true}`,
		"неповний record": `{"request_id": "abc-1", "ok": true, "record": {"city": "Lviv"}}`,
	}
	for name, body := range bodies {
		t.Run(name, func(t *testing.T) {
			action := handleResponse(context.Background(), []byte(body), saveMustNotBeCalled(t))
			if action != rejectResponse {
				t.Fatalf("дія = %d, очікувався reject", action)
			}
		})
	}
}

func TestHandleResponseRetriesWhenDatabaseFails(t *testing.T) {
	save := func(context.Context, WeatherRecord) (bool, error) {
		return false, errors.New("база недоступна")
	}

	if action := handleResponse(context.Background(), []byte(goodResponse), save); action != retryResponse {
		t.Fatalf("дія = %d, очікувався retry", action)
	}
}
