// Package openmeteo talks to the Open-Meteo forecast API and maps its responses
// to normalized observations. No HTTP server and no database here.
package openmeteo

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// MaxHistoryDays is the Open-Meteo `past_days` limit.
const MaxHistoryDays = 92

var weatherVariables = []string{
	"temperature_2m",
	"relative_humidity_2m",
	"apparent_temperature",
	"precipitation",
	"wind_speed_10m",
	"wind_direction_10m",
	"weather_code",
}

// Location is the place to fetch weather for; the caller passes it with every request.
type Location struct {
	Name      string
	Latitude  float64
	Longitude float64
}

// FetcherError means the weather API could not be reached or answered with an error.
type FetcherError struct {
	Message string
}

func (e *FetcherError) Error() string { return e.Message }

type Client struct {
	baseURL string
	http    *http.Client
}

func NewClient(baseURL string) *Client {
	return &Client{baseURL: baseURL, http: &http.Client{Timeout: 10 * time.Second}}
}

// FetchCurrent fetches the current weather for a location → one observation.
func (c *Client) FetchCurrent(ctx context.Context, loc Location) (Observation, error) {
	body, err := c.requestForecast(ctx, loc, map[string]string{
		"current": strings.Join(weatherVariables, ","),
	})
	if err != nil {
		return Observation{}, err
	}
	return MapCurrent(body, loc)
}

// FetchRecentHistory fetches hourly weather for the last `days` days up to now.
func (c *Client) FetchRecentHistory(ctx context.Context, loc Location, days int) ([]Observation, error) {
	if days < 1 || days > MaxHistoryDays {
		return nil, fmt.Errorf("days must be an integer between 1 and %d", MaxHistoryDays)
	}
	body, err := c.requestForecast(ctx, loc, map[string]string{
		"hourly":        strings.Join(weatherVariables, ","),
		"past_days":     strconv.Itoa(days),
		"forecast_days": "1", // includes today; future hours are filtered out by the mapper
	})
	if err != nil {
		return nil, err
	}
	return MapHourly(body, loc, time.Now())
}

// requestForecast calls the forecast endpoint. Times are requested as unix
// timestamps (UTC) to avoid timezone ambiguity.
func (c *Client) requestForecast(ctx context.Context, loc Location, extra map[string]string) (*Response, error) {
	u, err := url.Parse(c.baseURL)
	if err != nil {
		return nil, fmt.Errorf("invalid OPEN_METEO_BASE_URL: %w", err)
	}
	q := url.Values{}
	q.Set("latitude", strconv.FormatFloat(loc.Latitude, 'f', -1, 64))
	q.Set("longitude", strconv.FormatFloat(loc.Longitude, 'f', -1, 64))
	q.Set("timeformat", "unixtime")
	q.Set("timezone", "GMT")
	q.Set("wind_speed_unit", "kmh")
	for k, v := range extra {
		q.Set(k, v)
	}
	u.RawQuery = q.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, &FetcherError{Message: "Open-Meteo request failed: " + err.Error()}
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		raw, _ := io.ReadAll(resp.Body)
		return nil, &FetcherError{Message: fmt.Sprintf("Open-Meteo responded with %d: %s", resp.StatusCode, raw)}
	}

	var out Response
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, &FetcherError{Message: "Open-Meteo returned invalid JSON: " + err.Error()}
	}
	return &out, nil
}
