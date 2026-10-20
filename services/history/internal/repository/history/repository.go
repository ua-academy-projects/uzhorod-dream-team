package history

import (
	"context"
	"history/internal/model"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Repository interface {
	GetHistory(ctx context.Context, symbol string, date time.Time) ([]model.Bar, error)
	GetLast(ctx context.Context, symbol string) ([]model.Bar, error)
	SaveBars(ctx context.Context, symbol string, bars []model.Bar) error
	GetLastOpenTime(ctx context.Context, symbol string) (*time.Time, error)
}

type repository struct {
	psql *pgxpool.Pool
}

func NewRepository(
	psql *pgxpool.Pool,
) Repository {
	return &repository{
		psql: psql,
	}
}
