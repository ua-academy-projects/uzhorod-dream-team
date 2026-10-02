package measurements

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Repository interface {
	InsertBatch(ctx context.Context, measurements []Measurement) error
	GetLatestTimestampForLocation(ctx context.Context, locationID int) (time.Time, error)
	GetHistory(ctx context.Context, locationID int, parameterName string, from, to time.Time) ([]MeasurementData, error)
}

type repoImpl struct {
	pool *pgxpool.Pool
}

func NewRepository(pool *pgxpool.Pool) Repository {
	return &repoImpl{pool: pool}
}

func (r *repoImpl) InsertBatch(ctx context.Context, measurements []Measurement) error {
	if len(measurements) == 0 {
		return nil
	}

	batch := &pgx.Batch{}
	query := `
		INSERT INTO measurements (location_id, parameter_id, value, timestamp)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (location_id, parameter_id, timestamp) DO NOTHING
	`
	for _, m := range measurements {
		batch.Queue(query, m.LocationID, m.ParameterID, m.Value, m.Timestamp)
	}

	br := r.pool.SendBatch(ctx, batch)
	defer br.Close()

	for i := 0; i < len(measurements); i++ {
		if _, err := br.Exec(); err != nil {
			return err
		}
	}
	return nil
}

func (r *repoImpl) GetLatestTimestampForLocation(ctx context.Context, locationID int) (time.Time, error) {
	var t time.Time
	query := `SELECT timestamp FROM measurements WHERE location_id = $1 ORDER BY timestamp DESC LIMIT 1`
	err := r.pool.QueryRow(ctx, query, locationID).Scan(&t)
	return t, err
}

func (r *repoImpl) GetHistory(ctx context.Context, locationID int, parameterName string, from, to time.Time) ([]MeasurementData, error) {
	query := `
		SELECT m.value, m.timestamp
		FROM measurements m
		JOIN parameters p ON m.parameter_id = p.id
		WHERE m.location_id = $1 AND p.name = $2 AND m.timestamp >= $3 AND m.timestamp <= $4
		ORDER BY m.timestamp ASC
	`
	rows, err := r.pool.Query(ctx, query, locationID, parameterName, from, to)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var data []MeasurementData
	for rows.Next() {
		var md MeasurementData
		if err := rows.Scan(&md.Value, &md.Timestamp); err != nil {
			return nil, err
		}
		data = append(data, md)
	}
	return data, nil
}
