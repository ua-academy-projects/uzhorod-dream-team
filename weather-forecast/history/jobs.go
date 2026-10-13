package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"time"
)

const currentWeather = "current_weather"
const temperatureHistory = "temperature_history"

var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

type WeatherRequest struct {
	RequestID string             `json:"request_id"`
	Type      string             `json:"type"`
	City      string             `json:"city"`
	Latitude  float64            `json:"latitude"`
	Longitude float64            `json:"longitude"`
	ExpiresAt time.Time          `json:"expires_at"`
	Ranges    []temperatureRange `json:"ranges,omitempty"`
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
type Collector struct {
	store     Repository
	jobs      JobRepository
	publisher JobPublisher
	config    Config
}

func newRequestID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}

func (c *Collector) submit(ctx context.Context, kind string, ranges []temperatureRange) (Job, error) {
	id, err := newRequestID()
	if err != nil {
		return Job{}, err
	}
	request := WeatherRequest{id, kind, c.config.City, c.config.Latitude, c.config.Longitude,
		time.Now().UTC().Add(c.config.JobTimeout), ranges}
	job, err := c.jobs.CreateJob(ctx, request)
	if err != nil {
		return job, err
	}
	if err := c.publish(ctx, request); err != nil {
		return job, &APIError{Status: http.StatusServiceUnavailable,
			Message: "RabbitMQ publication was not confirmed; check this job before retrying", RequestID: id}
	}
	return job, nil
}

func (c *Collector) publish(ctx context.Context, request WeatherRequest) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := c.publisher.Publish(ctx, request); err != nil {
		return err
	}
	return c.jobs.MarkPublished(ctx, request.RequestID)
}

func (c *Collector) Collect(ctx context.Context) (Job, error) {
	return c.submit(ctx, currentWeather, nil)
}
func (c *Collector) SyncTemperature(ctx context.Context, days int) (Job, error) {
	if days < 1 || days > 92 {
		return Job{}, fmt.Errorf("temperature history days must be between 1 and 92")
	}
	end := time.Now().UTC().Truncate(time.Hour)
	start := end.Add(-time.Duration(days) * 24 * time.Hour)
	missing, err := c.store.MissingTemperatureHours(ctx, c.config.City, start, end)
	if err != nil {
		return Job{}, err
	}
	return c.submit(ctx, temperatureHistory, temperatureRanges(start, end, missing))
}

// Pending publications survive a crash between PostgreSQL commit and AMQP confirm.
func (c *Collector) recoverJobs(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		if err := c.jobs.ExpireJobs(ctx); err != nil && ctx.Err() == nil {
			log.Print("Job expiration: database unavailable")
		}
		requests, err := c.jobs.UnpublishedJobs(ctx)
		if err == nil {
			for _, request := range requests {
				if err := c.publish(ctx, request); err != nil && ctx.Err() == nil {
					log.Printf("Pending publication request_id=%s is not confirmed", request.RequestID)
				}
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func validateResponse(request WeatherRequest, response WeatherResponse) (Weather, []TemperaturePoint, *JobFailure) {
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
	if request.Type == currentWeather {
		weather, err := decodeWeather(response.Data)
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
	if request.Type != temperatureHistory || json.Unmarshal(response.Data, &data) != nil || data.City != request.City || len(request.Ranges) == 0 {
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
			if point.WeatherTime == nil || point.TemperatureC == nil || !finite(*point.TemperatureC) {
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
