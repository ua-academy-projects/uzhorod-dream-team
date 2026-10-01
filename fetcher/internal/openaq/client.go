package openaq

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"

	"fetcher/internal/config"
)

const (
	KyivBBox = "30.2,50.3,30.8,50.6"
	MaxLimit = "1000"
)

type Client interface {
	GetLocations(ctx context.Context) ([]LocationResult, error)
	GetLocationLatest(ctx context.Context, locationID int) ([]LatestResult, error)
	GetLocationSensors(ctx context.Context, locationID int) ([]SensorResult, error)
	GetSensorMeasurements(ctx context.Context, sensorID int, from, to string) ([]MeasurementResult, error)
}

type clientImpl struct {
	baseURL     string
	apiKey      string
	httpClient  *http.Client
	rateLimiter <-chan time.Time
}

func NewClient(cfg *config.Config) Client {
	rateLimiter := time.Tick(1 * time.Second)

	return &clientImpl{
		baseURL: cfg.OpenAQURL,
		apiKey:  cfg.OpenAQAPIKey,
		httpClient: &http.Client{
			Timeout: cfg.HTTPTimeout,
		},
		rateLimiter: rateLimiter,
	}
}

func (c *clientImpl) doRequest(ctx context.Context, method, endpoint string, query url.Values) (*http.Response, error) {
	<-c.rateLimiter

	u, err := url.Parse(c.baseURL + endpoint)
	if err != nil {
		return nil, err
	}
	if query != nil {
		u.RawQuery = query.Encode()
	}

	req, err := http.NewRequestWithContext(ctx, method, u.String(), nil)
	if err != nil {
		return nil, err
	}

	if c.apiKey != "" {
		req.Header.Set("X-API-Key", c.apiKey)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		resp.Body.Close()
		return nil, fmt.Errorf("unexpected status code %d: %s", resp.StatusCode, resp.Status)
	}

	return resp, nil
}

func (c *clientImpl) GetLocations(ctx context.Context) ([]LocationResult, error) {
	query := url.Values{}
	query.Set("bbox", KyivBBox)
	query.Set("limit", MaxLimit)

	resp, err := c.doRequest(ctx, http.MethodGet, "/v3/locations", query)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var data LocationsResponse
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}
	return data.Results, nil
}

func (c *clientImpl) GetLocationLatest(ctx context.Context, locationID int) ([]LatestResult, error) {
	endpoint := fmt.Sprintf("/v3/locations/%d/latest", locationID)
	resp, err := c.doRequest(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var data LocationsLatestResponse
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}
	return data.Results, nil
}

func (c *clientImpl) GetLocationSensors(ctx context.Context, locationID int) ([]SensorResult, error) {
	endpoint := fmt.Sprintf("/v3/locations/%d/sensors", locationID)
	resp, err := c.doRequest(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var data SensorsResponse
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}
	return data.Results, nil
}

func (c *clientImpl) GetSensorMeasurements(ctx context.Context, sensorID int, from, to string) ([]MeasurementResult, error) {
	query := url.Values{}
	query.Set("limit", MaxLimit)
	if from != "" {
		query.Set("datetime_from", from)
	}
	if to != "" {
		query.Set("datetime_to", to)
	}

	endpoint := fmt.Sprintf("/v3/sensors/%d/measurements", sensorID)
	resp, err := c.doRequest(ctx, http.MethodGet, endpoint, query)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var data MeasurementsResponse
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}
	return data.Results, nil
}
