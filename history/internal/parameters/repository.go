package parameters

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Repository interface {
	GetOrCreate(ctx context.Context, name, unit string) (int, error)
	GetForLocation(ctx context.Context, locationID int) ([]Parameter, error)
}

type repoImpl struct {
	pool *pgxpool.Pool
}

func NewRepository(pool *pgxpool.Pool) Repository {
	return &repoImpl{pool: pool}
}

func (r *repoImpl) GetOrCreate(ctx context.Context, name, unit string) (int, error) {
	var id int
	query := `
		INSERT INTO parameters (name, unit) 
		VALUES ($1, $2)
		ON CONFLICT (name) DO UPDATE SET name=EXCLUDED.name RETURNING id
	`
	err := r.pool.QueryRow(ctx, query, name, unit).Scan(&id)
	return id, err
}

func (r *repoImpl) GetForLocation(ctx context.Context, locationID int) ([]Parameter, error) {
	query := `
		SELECT DISTINCT p.name, p.unit
		FROM measurements m
		JOIN parameters p ON m.parameter_id = p.id
		WHERE m.location_id = $1
	`
	rows, err := r.pool.Query(ctx, query, locationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var params []Parameter
	for rows.Next() {
		var p Parameter
		if err := rows.Scan(&p.Name, &p.Unit); err != nil {
			return nil, err
		}
		params = append(params, p)
	}
	return params, nil
}
