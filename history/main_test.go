package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHistoryHandlerReturnsRecordsAsJSON(t *testing.T) {
	want := []WeatherRecord{{
		City:         "Lviv",
		TemperatureC: 12.5,
		ObservedAt:   time.Date(2026, 10, 4, 21, 0, 0, 0, time.UTC),
		FetchedAt:    time.Date(2026, 10, 4, 21, 1, 0, 0, time.UTC),
	}}
	handler := historyHandler(func(context.Context) ([]WeatherRecord, error) {
		return want, nil
	})
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/history", nil)

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("статус = %d, очікувався %d", response.Code, http.StatusOK)
	}
	if got := response.Header().Get("Content-Type"); got != "application/json; charset=utf-8" {
		t.Fatalf("Content-Type = %q, очікувався JSON", got)
	}

	var got []WeatherRecord
	if err := json.Unmarshal(response.Body.Bytes(), &got); err != nil {
		t.Fatalf("не вдалося прочитати JSON: %v", err)
	}
	if len(got) != 1 || got[0] != want[0] {
		t.Fatalf("записи = %#v, очікувалися %#v", got, want)
	}
}

func TestHistoryHandlerReturnsServerErrorWhenReadingFails(t *testing.T) {
	handler := historyHandler(func(context.Context) ([]WeatherRecord, error) {
		return nil, errors.New("помилка бази")
	})
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/history", nil)

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusInternalServerError {
		t.Fatalf("статус = %d, очікувався %d", response.Code, http.StatusInternalServerError)
	}
}

func TestHistoryHandlerRejectsOtherMethods(t *testing.T) {
	handler := historyHandler(func(context.Context) ([]WeatherRecord, error) {
		t.Fatal("запит до бази не має виконуватися для невірного HTTP-методу")
		return nil, nil
	})
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/api/history", nil)

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusMethodNotAllowed {
		t.Fatalf("статус = %d, очікувався %d", response.Code, http.StatusMethodNotAllowed)
	}
	if got := response.Header().Get("Allow"); got != http.MethodGet {
		t.Fatalf("Allow = %q, очікувався %q", got, http.MethodGet)
	}
}

func TestUIHandlerServesIndexAndAssets(t *testing.T) {
	handler := uiHandler()
	for _, path := range []string{"/", "/app.js", "/style.css"} {
		response := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodGet, path, nil)

		handler.ServeHTTP(response, request)

		if response.Code != http.StatusOK {
			t.Errorf("GET %s: статус = %d, очікувався %d", path, response.Code, http.StatusOK)
			continue
		}
		if got := response.Header().Get("Cache-Control"); got != "no-cache" {
			t.Errorf("GET %s: Cache-Control = %q, очікувався no-cache", path, got)
		}
		if path == "/" {
			body, err := io.ReadAll(response.Body)
			if err != nil {
				t.Fatalf("не вдалося прочитати HTML: %v", err)
			}
			if !strings.Contains(string(body), "Погода у Львові") {
				t.Error("головна сторінка не містить заголовка про погоду у Львові")
			}
		}
	}
}
