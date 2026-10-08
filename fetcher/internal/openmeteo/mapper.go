package openmeteo

import (
	"errors"
	"time"
)

// Observation is the normalized weather reading returned by the Fetcher.
// Measured values are pointers so that "no value" is serialized as JSON null.
type Observation struct {
	LocationName        string    `json:"locationName"`
	Latitude            float64   `json:"latitude"`
	Longitude           float64   `json:"longitude"`
	ObservedAt          time.Time `json:"observedAt"`
	Temperature         *float64  `json:"temperature"`
	ApparentTemperature *float64  `json:"apparentTemperature"`
	Humidity            *float64  `json:"humidity"`
	Precipitation       *float64  `json:"precipitation"`
	WindSpeed           *float64  `json:"windSpeed"`
	WindDirection       *float64  `json:"windDirection"`
	WeatherCode         *int      `json:"weatherCode"`
	Source              string    `json:"source"`
}

// Response is the part of the Open-Meteo JSON response that we use.
type Response struct {
	Current *Current `json:"current"`
	Hourly  *Hourly  `json:"hourly"`
}

type Current struct {
	Time                int64    `json:"time"`
	Temperature         *float64 `json:"temperature_2m"`
	Humidity            *float64 `json:"relative_humidity_2m"`
	ApparentTemperature *float64 `json:"apparent_temperature"`
	Precipitation       *float64 `json:"precipitation"`
	WindSpeed           *float64 `json:"wind_speed_10m"`
	WindDirection       *float64 `json:"wind_direction_10m"`
	WeatherCode         *int     `json:"weather_code"`
}

// Hourly holds column arrays, one entry per hour; values can be null.
type Hourly struct {
	Time                []int64    `json:"time"`
	Temperature         []*float64 `json:"temperature_2m"`
	Humidity            []*float64 `json:"relative_humidity_2m"`
	ApparentTemperature []*float64 `json:"apparent_temperature"`
	Precipitation       []*float64 `json:"precipitation"`
	WindSpeed           []*float64 `json:"wind_speed_10m"`
	WindDirection       []*float64 `json:"wind_direction_10m"`
	WeatherCode         []*int     `json:"weather_code"`
}

// MapCurrent maps an Open-Meteo response containing a `current` block to one observation.
func MapCurrent(r *Response, loc Location) (Observation, error) {
	if r == nil || r.Current == nil || r.Current.Time == 0 {
		return Observation{}, errors.New(`Open-Meteo response has no "current" data`)
	}
	c := r.Current
	return Observation{
		LocationName:        loc.Name,
		Latitude:            loc.Latitude,
		Longitude:           loc.Longitude,
		ObservedAt:          time.Unix(c.Time, 0).UTC(),
		Temperature:         c.Temperature,
		ApparentTemperature: c.ApparentTemperature,
		Humidity:            c.Humidity,
		Precipitation:       c.Precipitation,
		WindSpeed:           c.WindSpeed,
		WindDirection:       c.WindDirection,
		WeatherCode:         c.WeatherCode,
		Source:              "current",
	}, nil
}

// at returns s[i], or nil if the column is shorter than the time column.
func at[T any](s []*T, i int) *T {
	if i < len(s) {
		return s[i]
	}
	return nil
}

// MapHourly maps an Open-Meteo response containing an `hourly` block to observations.
// It skips future hours and hours without a temperature value.
func MapHourly(r *Response, loc Location, now time.Time) ([]Observation, error) {
	if r == nil || r.Hourly == nil || r.Hourly.Time == nil {
		return nil, errors.New(`Open-Meteo response has no "hourly" data`)
	}
	h := r.Hourly
	out := make([]Observation, 0, len(h.Time))
	for i, t := range h.Time {
		temperature := at(h.Temperature, i)
		if t > now.Unix() || temperature == nil {
			continue
		}
		out = append(out, Observation{
			LocationName:        loc.Name,
			Latitude:            loc.Latitude,
			Longitude:           loc.Longitude,
			ObservedAt:          time.Unix(t, 0).UTC(),
			Temperature:         temperature,
			ApparentTemperature: at(h.ApparentTemperature, i),
			Humidity:            at(h.Humidity, i),
			Precipitation:       at(h.Precipitation, i),
			WindSpeed:           at(h.WindSpeed, i),
			WindDirection:       at(h.WindDirection, i),
			WeatherCode:         at(h.WeatherCode, i),
			Source:              "historical",
		})
	}
	return out, nil
}
