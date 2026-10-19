package main

import (
	"encoding/json"
	"math"
	"net/http"
	"strings"
	"time"
)

type Weather struct {
	City            string    `json:"city"`
	Latitude        float64   `json:"latitude"`
	Longitude       float64   `json:"longitude"`
	TemperatureC    float64   `json:"temperature_c"`
	HumidityPercent int       `json:"humidity_percent"`
	WindSpeedKMH    float64   `json:"wind_speed_kmh"`
	WeatherTime     time.Time `json:"weather_time"`
}

type Snapshot struct {
	ID int64 `json:"id"`
	Weather
	FetchedAt time.Time `json:"fetched_at"`
}

type APIError struct {
	Status    int
	Message   string
	RequestID string
}

func (e *APIError) Error() string { return e.Message }

var errBusy = &APIError{Status: http.StatusConflict, Message: "Collection is already running; try again later"}

// Pointers distinguish a missing field from a valid zero.
type weatherPayload struct {
	City            *string    `json:"city"`
	Latitude        *float64   `json:"latitude"`
	Longitude       *float64   `json:"longitude"`
	TemperatureC    *float64   `json:"temperature_c"`
	HumidityPercent *int       `json:"humidity_percent"`
	WindSpeedKMH    *float64   `json:"wind_speed_kmh"`
	WeatherTime     *time.Time `json:"weather_time"`
}

func decodeWeather(body []byte) (Weather, error) {
	var weather Weather
	var p weatherPayload
	if len(body) > 64*1024 || json.Unmarshal(body, &p) != nil ||
		p.City == nil || p.Latitude == nil || p.Longitude == nil || p.TemperatureC == nil ||
		p.HumidityPercent == nil || p.WindSpeedKMH == nil || p.WeatherTime == nil {
		return weather, &APIError{Status: http.StatusBadGateway, Message: "Fetcher returned invalid or incomplete data"}
	}
	weather = Weather{*p.City, *p.Latitude, *p.Longitude, *p.TemperatureC, *p.HumidityPercent, *p.WindSpeedKMH, *p.WeatherTime}
	_, offset := weather.WeatherTime.Zone()
	if strings.TrimSpace(weather.City) == "" || len([]rune(weather.City)) > 100 ||
		!finite(weather.Latitude) || weather.Latitude < -90 || weather.Latitude > 90 ||
		!finite(weather.Longitude) || weather.Longitude < -180 || weather.Longitude > 180 ||
		!finite(weather.TemperatureC) || weather.HumidityPercent < 0 || weather.HumidityPercent > 100 ||
		!finite(weather.WindSpeedKMH) || weather.WindSpeedKMH < 0 || weather.WeatherTime.IsZero() ||
		weather.WeatherTime.Year() < 1 || weather.WeatherTime.Year() > 9999 || offset != 0 {
		return Weather{}, &APIError{Status: http.StatusBadGateway, Message: "Values in the Fetcher response failed validation"}
	}
	weather.WeatherTime = weather.WeatherTime.UTC()
	return weather, nil
}

func finite(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }
