package settings

import (
	"context"
	"history/internal/model"
)

type Repository interface {
	GetSettings(ctx context.Context, id string) (*model.Settings, error)
	SetSettings(ctx context.Context, id string, settings model.Settings) error
}
