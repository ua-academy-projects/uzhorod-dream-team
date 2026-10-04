package locations

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Repository interface {
	Upsert(ctx context.Context, loc Location) error
	SetLastSyncTime(ctx context.Context, locationID int, syncedAt time.Time) error
	GetAll(ctx context.Context) ([]Location, error)
}

type repoImpl struct {
	pool *pgxpool.Pool
}

func NewRepository(pool *pgxpool.Pool) Repository {
	return &repoImpl{pool: pool}
}

func (r *repoImpl) Upsert(ctx context.Context, loc Location) error {
	query := `
		INSERT INTO locations (id, name, lat, lon)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (id) DO UPDATE SET 
			name = EXCLUDED.name, 
			lat = EXCLUDED.lat, 
			lon = EXCLUDED.lon
	`
	_, err := r.pool.Exec(ctx, query, loc.ID, loc.Name, loc.Lat, loc.Lon)
	return err
}

func (r *repoImpl) SetLastSyncTime(ctx context.Context, locationID int, syncedAt time.Time) error {
	_, err := r.pool.Exec(ctx, `UPDATE locations SET last_sync_time = $2 WHERE id = $1`, locationID, syncedAt)
	return err
}

func (r *repoImpl) GetAll(ctx context.Context) ([]Location, error) {
	query := `SELECT id, name, lat, lon, last_sync_time FROM locations`
	rows, err := r.pool.Query(ctx, query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var locs []Location
	for rows.Next() {
		var l Location
		if err := rows.Scan(&l.ID, &l.Name, &l.Lat, &l.Lon, &l.LastSyncTime); err != nil {
			return nil, err
		}
		locs = append(locs, l)
	}
	return locs, nil
}
