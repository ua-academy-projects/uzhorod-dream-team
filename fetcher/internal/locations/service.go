package locations

import (
	"context"
	"fetcher/internal/openaq"
)

type Service interface {
	GetLocationsLatest(ctx context.Context) ([]Location, error)
	GetLocationMeasurements(ctx context.Context, locationID int, from, to string) ([]Measurement, error)
}

type serviceImpl struct {
	client openaq.Client
}

func NewService(client openaq.Client) Service {
	return &serviceImpl{
		client: client,
	}
}

func (s *serviceImpl) GetLocationsLatest(ctx context.Context) ([]Location, error) {
	rawLocations, err := s.client.GetLocations(ctx)
	if err != nil {
		return nil, err
	}

	var locations []Location
	for _, rawLoc := range rawLocations {
		loc := Location{
			ID:   rawLoc.ID,
			Name: rawLoc.Name,
			Lat:  rawLoc.Coordinates.Lat,
			Lon:  rawLoc.Coordinates.Lon,
		}

		latestResults, err := s.client.GetLocationLatest(ctx, loc.ID)
		if err != nil {
			return nil, err
		}

		sensorMap := make(map[int]openaq.SensorResult)
		for _, sensor := range rawLoc.Sensors {
			sensorMap[sensor.ID] = sensor
		}

		var measurements []Measurement
		for _, latest := range latestResults {
			if sensor, ok := sensorMap[latest.SensorsID]; ok {
				measurements = append(measurements, Measurement{
					Parameter: sensor.Parameter.Name,
					Value:     latest.Value,
					Unit:      sensor.Parameter.Units,
					Timestamp: latest.Datetime.UTC,
				})
			}
		}

		loc.Latest = measurements
		locations = append(locations, loc)
	}

	return locations, nil
}

func (s *serviceImpl) GetLocationMeasurements(ctx context.Context, locationID int, from, to string) ([]Measurement, error) {
	sensors, err := s.client.GetLocationSensors(ctx, locationID)
	if err != nil {
		return nil, err
	}

	var allMeasurements []Measurement

	for _, sensor := range sensors {
		rawMeasurements, err := s.client.GetSensorMeasurements(ctx, sensor.ID, from, to)
		if err != nil {
			return nil, err
		}

		for _, m := range rawMeasurements {
			allMeasurements = append(allMeasurements, Measurement{
				Parameter: sensor.Parameter.Name,
				Value:     m.Value,
				Unit:      sensor.Parameter.Units,
				Timestamp: m.Period.DatetimeTo.UTC,
			})
		}
	}

	return allMeasurements, nil
}
