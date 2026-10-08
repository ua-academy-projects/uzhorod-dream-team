package openmeteo

import (
	"encoding/json"
	"testing"
	"time"
)

var testLocation = Location{Name: "Testville", Latitude: 1.5, Longitude: 2.5}

func parse(t *testing.T, raw string) *Response {
	t.Helper()
	var r Response
	if err := json.Unmarshal([]byte(raw), &r); err != nil {
		t.Fatal(err)
	}
	return &r
}

func TestMapCurrent(t *testing.T) {
	r := parse(t, `{"current":{"time":1735732800,"temperature_2m":3.4,"relative_humidity_2m":81,
		"apparent_temperature":0.2,"precipitation":0.1,"wind_speed_10m":12.5,"wind_direction_10m":240,"weather_code":61}}`)

	obs, err := MapCurrent(r, testLocation)
	if err != nil {
		t.Fatal(err)
	}
	if !obs.ObservedAt.Equal(time.Date(2025, 1, 1, 12, 0, 0, 0, time.UTC)) {
		t.Errorf("observedAt = %v", obs.ObservedAt)
	}
	if obs.LocationName != "Testville" || obs.Source != "current" {
		t.Errorf("unexpected observation: %+v", obs)
	}
	if obs.Temperature == nil || *obs.Temperature != 3.4 || obs.WeatherCode == nil || *obs.WeatherCode != 61 {
		t.Errorf("unexpected values: %+v", obs)
	}
}

func TestMapCurrentMissingBlock(t *testing.T) {
	if _, err := MapCurrent(&Response{}, testLocation); err == nil {
		t.Fatal("expected an error when the current block is missing")
	}
}

func TestMapHourlyDropsFutureAndEmptyHours(t *testing.T) {
	const t0 = 1735732800
	r := parse(t, `{"hourly":{"time":[1735732800,1735736400,1735740000,1735743600],
		"temperature_2m":[1,null,3,4],"weather_code":[0,0,2,3]}}`)
	now := time.Unix(t0+7200, 0)

	rows, err := MapHourly(r, testLocation, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("got %d rows, want 2", len(rows))
	}
	if !rows[0].ObservedAt.Equal(time.Unix(t0, 0)) || !rows[1].ObservedAt.Equal(time.Unix(t0+7200, 0)) {
		t.Errorf("unexpected times: %v, %v", rows[0].ObservedAt, rows[1].ObservedAt)
	}
	if *rows[1].Temperature != 3 || *rows[1].WeatherCode != 2 || rows[1].Source != "historical" {
		t.Errorf("unexpected row: %+v", rows[1])
	}
	if rows[0].Humidity != nil {
		t.Error("humidity should be nil when the column is absent")
	}
}
