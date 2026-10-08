package syncer

import (
	"context"
	"encoding/json"
	"time"

	"history/internal/config"
	"history/internal/rabbitmq"
)

type FetcherLocation struct {
	ID     int                  `json:"id"`
	Name   string               `json:"name"`
	Lat    float64              `json:"lat"`
	Lon    float64              `json:"lon"`
	Latest []FetcherMeasurement `json:"latest"`
}

type FetcherMeasurement struct {
	Parameter string  `json:"parameter"`
	Value     float64 `json:"value"`
	Unit      string  `json:"unit"`
	Timestamp string  `json:"timestamp"`
}

type FetcherClient interface {
	GetLocations(ctx context.Context) ([]FetcherLocation, error)
	GetLocationsLatest(ctx context.Context) ([]FetcherLocation, error)
	GetLocationMeasurements(ctx context.Context, locationID int, from string) ([]FetcherMeasurement, error)
}

type requester interface {
	Call(context.Context, rabbitmq.Request) (json.RawMessage, error)
}

type fetcherClientImpl struct {
	client  requester
	timeout time.Duration
	close   func()
}

func NewFetcherClient(ctx context.Context, cfg config.RabbitMQ, timeout time.Duration) *fetcherClientImpl {
	client := rabbitmq.NewClient(ctx, cfg)
	return &fetcherClientImpl{client: client, timeout: timeout, close: client.Close}
}

func (c *fetcherClientImpl) Close() { c.close() }

func (c *fetcherClientImpl) call(ctx context.Context, request rabbitmq.Request, result any) error {
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	data, err := c.client.Call(ctx, request)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, result)
}

func (c *fetcherClientImpl) GetLocations(ctx context.Context) ([]FetcherLocation, error) {
	var result []FetcherLocation
	err := c.call(ctx, rabbitmq.Request{Operation: rabbitmq.ListLocations}, &result)
	return result, err
}

func (c *fetcherClientImpl) GetLocationsLatest(ctx context.Context) ([]FetcherLocation, error) {
	var result []FetcherLocation
	err := c.call(ctx, rabbitmq.Request{Operation: rabbitmq.LatestLocations}, &result)
	return result, err
}

func (c *fetcherClientImpl) GetLocationMeasurements(ctx context.Context, locationID int, from string) ([]FetcherMeasurement, error) {
	var result []FetcherMeasurement
	err := c.call(ctx, rabbitmq.Request{Operation: rabbitmq.LocationMeasurements, LocationID: locationID, From: from}, &result)
	return result, err
}
