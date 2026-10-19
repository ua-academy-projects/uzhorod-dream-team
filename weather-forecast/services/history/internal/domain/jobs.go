package domain

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"time"
)

var ErrInvalidDelivery = errors.New("unrecognized response message")

const CurrentWeather = "current_weather"

const TemperatureHistory = "temperature_history"

var UUIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

type WeatherRequest struct {
	RequestID string             `json:"request_id"`
	Type      string             `json:"type"`
	City      string             `json:"city"`
	Latitude  float64            `json:"latitude"`
	Longitude float64            `json:"longitude"`
	ExpiresAt time.Time          `json:"expires_at"`
	Ranges    []TemperatureRange `json:"ranges,omitempty"`
}

type JobFailure struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type WeatherResponse struct {
	RequestID string          `json:"request_id"`
	Type      string          `json:"type"`
	Status    string          `json:"status"`
	Data      json.RawMessage `json:"data"`
	Error     *JobFailure     `json:"error"`
}

type Job struct {
	RequestID   string          `json:"request_id"`
	Type        string          `json:"type"`
	Status      string          `json:"status"`
	CreatedAt   time.Time       `json:"created_at"`
	ExpiresAt   time.Time       `json:"expires_at"`
	ProcessedAt *time.Time      `json:"processed_at,omitempty"`
	Error       *JobFailure     `json:"error,omitempty"`
	Result      json.RawMessage `json:"result,omitempty"`
	Request     WeatherRequest  `json:"-"`
}

type JobRepository interface {
	CreateJob(context.Context, WeatherRequest) (Job, error)
	GetJob(context.Context, string) (Job, error)
	ExpireJobs(context.Context) error
	UnpublishedJobs(context.Context) ([]WeatherRequest, error)
	MarkPublished(context.Context, string) error
}

type JobPublisher interface {
	Publish(context.Context, WeatherRequest) error
}

func NewRequestID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}

func ValidateResponse(request WeatherRequest, response WeatherResponse) (Weather, []TemperaturePoint, *JobFailure) {
	invalid := &JobFailure{"invalid_response", "Fetcher returned invalid or incomplete weather data"}
	if response.RequestID != request.RequestID || response.Type != request.Type {
		return Weather{}, nil, invalid
	}
	if response.Status == "failed" {
		if response.Error == nil || response.Error.Code == "" || len(response.Error.Code) > 64 ||
			response.Error.Message == "" || len(response.Error.Message) > 300 {
			return Weather{}, nil, invalid
		}
		return Weather{}, nil, response.Error
	}
	if response.Status != "completed" || response.Error != nil {
		return Weather{}, nil, invalid
	}
	if request.Type == CurrentWeather {
		weather, err := DecodeWeather(response.Data)
		if err != nil || weather.City != request.City {
			return Weather{}, nil, invalid
		}
		return weather, nil, nil
	}
	var data struct {
		City   string `json:"city"`
		Points []struct {
			WeatherTime  *time.Time `json:"weather_time"`
			TemperatureC *float64   `json:"temperature_c"`
		} `json:"points"`
	}
	if request.Type != TemperatureHistory || json.Unmarshal(response.Data, &data) != nil || data.City != request.City || len(request.Ranges) == 0 {
		return Weather{}, nil, invalid
	}
	index := 0
	points := make([]TemperaturePoint, 0, len(data.Points))
	for _, interval := range request.Ranges {
		for hour := interval.Start; !hour.After(interval.End); hour = hour.Add(time.Hour) {
			if index >= len(data.Points) {
				return Weather{}, nil, invalid
			}
			point := data.Points[index]
			if point.WeatherTime == nil || point.TemperatureC == nil || !Finite(*point.TemperatureC) {
				return Weather{}, nil, invalid
			}
			_, offset := point.WeatherTime.Zone()
			if offset != 0 || !point.WeatherTime.Equal(hour) {
				return Weather{}, nil, invalid
			}
			points = append(points, TemperaturePoint{hour.UTC(), *point.TemperatureC})
			index++
		}
	}
	if index != len(data.Points) {
		return Weather{}, nil, invalid
	}
	return Weather{}, points, nil
}

type TemperatureRange struct {
	Start time.Time `json:"start"`
	End   time.Time `json:"end"`
}
