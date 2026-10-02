package syncer

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
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

type fetcherClientImpl struct {
	baseURL    string
	httpClient *http.Client
}

func NewFetcherClient(baseURL string, timeout time.Duration) FetcherClient {
	return &fetcherClientImpl{
		baseURL: baseURL,
		httpClient: &http.Client{
			Timeout: timeout,
		},
	}
}

func (c *fetcherClientImpl) GetLocations(ctx context.Context) ([]FetcherLocation, error) {
	url := fmt.Sprintf("%s/api/v1/locations", c.baseURL)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fetcher returned status %d", resp.StatusCode)
	}

	var locs []FetcherLocation
	if err := json.NewDecoder(resp.Body).Decode(&locs); err != nil {
		return nil, err
	}
	return locs, nil
}

func (c *fetcherClientImpl) GetLocationsLatest(ctx context.Context) ([]FetcherLocation, error) {
	url := fmt.Sprintf("%s/api/v1/locations/latest", c.baseURL)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fetcher returned status %d", resp.StatusCode)
	}

	var locs []FetcherLocation
	if err := json.NewDecoder(resp.Body).Decode(&locs); err != nil {
		return nil, err
	}
	return locs, nil
}

func (c *fetcherClientImpl) GetLocationMeasurements(ctx context.Context, locationID int, from string) ([]FetcherMeasurement, error) {
	url := fmt.Sprintf("%s/api/v1/locations/%d/measurements?from=%s", c.baseURL, locationID, from)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fetcher returned status %d", resp.StatusCode)
	}

	var measurements []FetcherMeasurement
	if err := json.NewDecoder(resp.Body).Decode(&measurements); err != nil {
		return nil, err
	}
	return measurements, nil
}
