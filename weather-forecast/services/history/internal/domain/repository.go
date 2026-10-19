package domain

import (
	"context"
	"time"
)

// A small interface allows testing collection without a real database.
type Repository interface {
	Insert(context.Context, Snapshot) (Snapshot, error)
	Latest(context.Context) (Snapshot, error)
	History(context.Context, int) ([]Snapshot, error)
	Temperature(context.Context, string, time.Time) ([]TemperaturePoint, error)
	SaveTemperature(context.Context, string, []TemperaturePoint) error
	MissingTemperatureHours(context.Context, string, time.Time, time.Time) ([]time.Time, error)
	Ping(context.Context) error
}
