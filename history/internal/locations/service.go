package locations

import (
	"context"
	"time"

	"history/internal/measurements"
	"history/internal/parameters"
)

type Service interface {
	GetLocations(ctx context.Context) ([]Location, error)
	GetLocationParameters(ctx context.Context, locationID int) ([]parameters.Parameter, error)
	GetLocationHistory(ctx context.Context, locationID int, parameter string, from, to time.Time) ([]measurements.MeasurementData, error)
}

type serviceImpl struct {
	locRepo   Repository
	paramRepo parameters.Repository
	measRepo  measurements.Repository
}

func NewService(locRepo Repository, paramRepo parameters.Repository, measRepo measurements.Repository) Service {
	return &serviceImpl{
		locRepo:   locRepo,
		paramRepo: paramRepo,
		measRepo:  measRepo,
	}
}

func (s *serviceImpl) GetLocations(ctx context.Context) ([]Location, error) {
	return s.locRepo.GetAll(ctx)
}

func (s *serviceImpl) GetLocationParameters(ctx context.Context, locationID int) ([]parameters.Parameter, error) {
	return s.paramRepo.GetForLocation(ctx, locationID)
}

func (s *serviceImpl) GetLocationHistory(ctx context.Context, locationID int, parameter string, from, to time.Time) ([]measurements.MeasurementData, error) {
	return s.measRepo.GetHistory(ctx, locationID, parameter, from, to)
}
