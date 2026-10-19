package domain_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"weather-history/internal/domain"
	"weather-history/internal/testutil"
)

func TestWeatherValidation(t *testing.T) {
	for _, body := range []string{`{}`, strings.Replace(testutil.ValidWeather, `"humidity_percent":70`, `"humidity_percent":null`, 1),
		strings.Replace(testutil.ValidWeather, `"humidity_percent":70`, `"humidity_percent":101`, 1),
		strings.Replace(testutil.ValidWeather, "09:15:00Z", "09:15:00+03:00", 1), testutil.ValidWeather + "{}"} {
		if _, err := domain.DecodeWeather([]byte(body)); err == nil {
			t.Fatalf("accepted invalid body: %s", body)
		}
	}
	if _, err := domain.DecodeWeather([]byte(testutil.ValidWeather)); err != nil {
		t.Fatal(err)
	}
}

func TestTemperatureResponseMustCoverAllRanges(t *testing.T) {
	start := time.Now().UTC().Truncate(time.Hour).Add(-3 * time.Hour)
	request := domain.WeatherRequest{RequestID: "00000000-0000-0000-0000-000000000001", Type: domain.TemperatureHistory, City: "Uzhhorod",
		Ranges: []domain.TemperatureRange{{start, start.Add(time.Hour)}, {start.Add(3 * time.Hour), start.Add(3 * time.Hour)}}}
	points := []domain.TemperaturePoint{{start, 10}, {start.Add(time.Hour), 11}, {start.Add(3 * time.Hour), 12}}
	payload := func(points []domain.TemperaturePoint, city string) json.RawMessage {
		b, _ := json.Marshal(struct {
			City   string                    `json:"city"`
			Points []domain.TemperaturePoint `json:"points"`
		}{city, points})
		return b
	}
	response := domain.WeatherResponse{RequestID: request.RequestID, Type: request.Type, Status: "completed", Data: payload(points, "Uzhhorod")}
	if _, saved, failure := domain.ValidateResponse(request, response); failure != nil || len(saved) != 3 {
		t.Fatalf("valid response: %v", failure)
	}
	for _, data := range []json.RawMessage{payload(points[:2], "Uzhhorod"), payload(points, "Lviv"), payload(append(points, points[2]), "Uzhhorod")} {
		response.Data = data
		if _, _, failure := domain.ValidateResponse(request, response); failure == nil {
			t.Fatal("invalid range accepted")
		}
	}
	response.Status = "failed"
	response.Error = &domain.JobFailure{"provider_timeout", "Open-Meteo did not respond in time"}
	if _, saved, failure := domain.ValidateResponse(request, response); failure.Code != "provider_timeout" || len(saved) != 0 {
		t.Fatal("provider error ignored")
	}
}
