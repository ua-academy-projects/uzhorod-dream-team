package sessions

import (
	"context"
	"errors"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type postgresRepository struct{ pool *pgxpool.Pool }

func NewPostgresRepository(pool *pgxpool.Pool) Repository { return &postgresRepository{pool: pool} }

func (r *postgresRepository) Load(ctx context.Context, id string, ttl time.Duration) (Preferences, error) {
	var p Preferences
	var locationID *string
	var days string
	err := r.pool.QueryRow(ctx, `UPDATE sessions SET expires_at=statement_timestamp()+$2::bigint*interval '1 millisecond' WHERE id=$1 AND expires_at>statement_timestamp()
 RETURNING preferences->'locationId', preferences->'parameter', preferences->'period.kind', preferences->'period.days', preferences->'period.from', preferences->'period.to'`, id, ttl.Milliseconds()).Scan(&locationID, &p.Parameter, &p.Period.Kind, &days, &p.Period.From, &p.Period.To)
	if errors.Is(err, pgx.ErrNoRows) {
		return Preferences{}, ErrNotFound
	}
	if err != nil {
		return Preferences{}, err
	}
	if locationID != nil {
		value, err := strconv.Atoi(*locationID)
		if err != nil {
			return Preferences{}, err
		}
		p.LocationID = &value
	}
	p.Period.Days, err = strconv.Atoi(days)
	if err != nil {
		return Preferences{}, err
	}
	return p, p.Validate()
}

func (r *postgresRepository) Save(ctx context.Context, id string, p Preferences, ttl time.Duration) error {
	if err := p.Validate(); err != nil {
		return err
	}
	var locationID *string
	if p.LocationID != nil {
		value := strconv.Itoa(*p.LocationID)
		locationID = &value
	}
	days := strconv.Itoa(p.Period.Days)
	keys := []string{"locationId", "parameter", "period.kind", "period.days", "period.from", "period.to"}
	values := []*string{locationID, p.Parameter, &p.Period.Kind, &days, &p.Period.From, &p.Period.To}
	_, err := r.pool.Exec(ctx, `INSERT INTO sessions(id,preferences,expires_at) VALUES($1,hstore($2::text[],$3::text[]),statement_timestamp()+$4::bigint*interval '1 millisecond') ON CONFLICT(id) DO UPDATE SET preferences=excluded.preferences,expires_at=excluded.expires_at`, id, keys, values, ttl.Milliseconds())
	return err
}
