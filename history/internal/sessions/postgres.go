package sessions

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type postgresRepository struct{ pool *pgxpool.Pool }

func NewPostgresRepository(pool *pgxpool.Pool) Repository { return &postgresRepository{pool: pool} }

func (r *postgresRepository) Load(ctx context.Context, id string, ttl time.Duration) (Preferences, error) {
	var data []byte
	err := r.pool.QueryRow(ctx, `UPDATE sessions SET expires_at=statement_timestamp()+$2::bigint*interval '1 millisecond' WHERE id=$1 AND expires_at>statement_timestamp() RETURNING preferences`, id, ttl.Milliseconds()).Scan(&data)
	if errors.Is(err, pgx.ErrNoRows) {
		return Preferences{}, ErrNotFound
	}
	if err != nil {
		return Preferences{}, err
	}
	var p Preferences
	if err = json.Unmarshal(data, &p); err != nil {
		return Preferences{}, err
	}
	return p, p.Validate()
}

func (r *postgresRepository) Save(ctx context.Context, id string, p Preferences, ttl time.Duration) error {
	data, err := json.Marshal(p)
	if err != nil {
		return err
	}
	_, err = r.pool.Exec(ctx, `INSERT INTO sessions(id,preferences,expires_at) VALUES($1,$2,statement_timestamp()+$3::bigint*interval '1 millisecond') ON CONFLICT(id) DO UPDATE SET preferences=excluded.preferences,expires_at=excluded.expires_at`, id, data, ttl.Milliseconds())
	return err
}
