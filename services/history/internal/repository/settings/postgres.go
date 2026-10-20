package settings

import (
	"context"
	"encoding/json"
	"errors"
	"history/internal/model"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type PSQLRepository struct {
	psql *pgxpool.Pool
}

func NewPSQLRepository(
	psql *pgxpool.Pool,
) Repository {
	return &PSQLRepository{
		psql: psql,
	}
}

func (r *PSQLRepository) GetSettings(
	ctx context.Context,
	id string,
) (*model.Settings, error) {
	var value []byte

	err := r.psql.QueryRow(ctx, `
		SELECT attributes -> 'value'
		FROM cache
		WHERE attributes -> 'key' = $1
			AND (expires_at IS NULL OR expires_at > NOW())
	`, id).Scan(&value)

	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			new := &model.Settings{
				Theme: model.ThemeAuto,
			}

			err := r.SetSettings(ctx, id, *new)
			if err != nil {
				return nil, err
			}

			return new, nil
		}

		return nil, err
	}

	var settings model.Settings

	if err := json.Unmarshal(value, &settings); err != nil {
		return nil, err
	}

	return &settings, nil
}

func (r *PSQLRepository) SetSettings(
	ctx context.Context,
	id string,
	settings model.Settings,
) error {
	value, err := json.Marshal(settings)

	if err != nil {
		return err
	}
	_, err = r.psql.Exec(ctx, `
		INSERT INTO cache (attributes, expires_at)
		VALUES (
			hstore('key', $1) || hstore('value', $2),
			$3
		)
		ON CONFLICT ((attributes -> 'key'))
		DO UPDATE SET
			attributes = EXCLUDED.attributes,
			expires_at = EXCLUDED.expires_at
	`, id, value, nil)

	return err
}
