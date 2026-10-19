package postgres

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"weather-history/internal/config"
)

type Store struct {
	pool    *pgxpool.Pool
	backend string
}

func New(pool *pgxpool.Pool, backend string) *Store {
	return &Store{pool: pool, backend: backend}
}

func (s *Store) queueBackend() string {
	if s.backend == "" {
		return config.BackendRabbitMQRedis
	}
	return s.backend
}

func (s *Store) Ping(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return s.pool.Ping(ctx)
}
