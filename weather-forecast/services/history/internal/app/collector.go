package app

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"time"

	"weather-history/internal/config"
	"weather-history/internal/domain"
)

type Collector struct {
	store     domain.Repository
	jobs      domain.JobRepository
	publisher domain.JobPublisher
	config    config.Config
}

func NewCollector(store domain.Repository, jobs domain.JobRepository, publisher domain.JobPublisher, cfg config.Config) *Collector {
	return &Collector{store: store, jobs: jobs, publisher: publisher, config: cfg}
}

func (c *Collector) GetJob(ctx context.Context, id string) (domain.Job, error) {
	return c.jobs.GetJob(ctx, id)
}

func (c *Collector) submit(ctx context.Context, kind string, ranges []domain.TemperatureRange) (domain.Job, error) {
	id, err := domain.NewRequestID()
	if err != nil {
		return domain.Job{}, err
	}
	request := domain.WeatherRequest{id, kind, c.config.City, c.config.Latitude, c.config.Longitude,
		time.Now().UTC().Add(c.config.JobTimeout), ranges}
	job, err := c.jobs.CreateJob(ctx, request)
	if err != nil {
		return job, err
	}
	if c.config.Backend == config.BackendPostgres {
		// The PostgreSQL request was committed together with its job.
		return job, nil
	}
	if err := c.publish(ctx, request); err != nil {
		return job, &domain.APIError{Status: http.StatusServiceUnavailable,
			Message: "RabbitMQ publication was not confirmed; check this job before retrying", RequestID: id}
	}
	return job, nil
}

func (c *Collector) publish(ctx context.Context, request domain.WeatherRequest) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := c.publisher.Publish(ctx, request); err != nil {
		return err
	}
	return c.jobs.MarkPublished(ctx, request.RequestID)
}

func (c *Collector) Collect(ctx context.Context) (domain.Job, error) {
	return c.submit(ctx, domain.CurrentWeather, nil)
}

func (c *Collector) SyncTemperature(ctx context.Context, days int) (domain.Job, error) {
	if days < 1 || days > 92 {
		return domain.Job{}, fmt.Errorf("temperature history days must be between 1 and 92")
	}
	end := time.Now().UTC().Truncate(time.Hour)
	start := end.Add(-time.Duration(days) * 24 * time.Hour)
	missing, err := c.store.MissingTemperatureHours(ctx, c.config.City, start, end)
	if err != nil {
		return domain.Job{}, err
	}
	return c.submit(ctx, domain.TemperatureHistory, temperatureRanges(start, end, missing))
}

// Pending publications survive a crash between PostgreSQL commit and AMQP confirm.
func (c *Collector) RecoverJobs(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		if err := c.jobs.ExpireJobs(ctx); err != nil && ctx.Err() == nil {
			log.Print("Job expiration: database unavailable")
		}
		if c.config.Backend != config.BackendPostgres {
			requests, err := c.jobs.UnpublishedJobs(ctx)
			if err == nil {
				for _, request := range requests {
					if err := c.publish(ctx, request); err != nil && ctx.Err() == nil {
						log.Printf("Pending publication request_id=%s is not confirmed", request.RequestID)
					}
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
