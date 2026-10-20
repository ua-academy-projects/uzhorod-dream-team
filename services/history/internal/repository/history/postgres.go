package history

import (
	"context"
	"history/internal/model"
	"time"
)

func (r *repository) GetHistory(
	ctx context.Context,
	symbol string,
	date time.Time,
) ([]model.Bar, error) {
	query := `
		SELECT
			id,
			symbol,
			open,
			high,
			low,
			close,
			volume,
			tick_volume,
			is_open,
			open_time,
			timestamp
		FROM bars
		WHERE symbol = $1
			AND open_time >= $2
			AND open_time < $2 + INTERVAL '1 day'
		ORDER BY open_time ASC
	`

	rows, err := r.psql.Query(ctx, query, symbol, date)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	bars := []model.Bar{}
	for rows.Next() {
		var b model.Bar

		if err := rows.Scan(
			&b.ID,
			&symbol,
			&b.Open,
			&b.High,
			&b.Low,
			&b.Close,
			&b.Volume,
			&b.TickVolume,
			&b.IsOpen,
			&b.OpenTime,
			&b.Timestamp,
		); err != nil {
			return nil, err
		}

		bars = append(bars, b)
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	return bars, nil
}

func (r *repository) GetLast(
	ctx context.Context,
	symbol string,
) ([]model.Bar, error) {
	query := `
		SELECT *
		FROM (
			SELECT *
			FROM bars
			WHERE symbol = $1
			ORDER BY open_time DESC
			LIMIT 2
		) t
		ORDER BY open_time ASC
	`

	rows, err := r.psql.Query(ctx, query, symbol)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var bars []model.Bar

	for rows.Next() {
		var b model.Bar

		err := rows.Scan(
			&b.ID,
			&symbol,
			&b.Open,
			&b.High,
			&b.Low,
			&b.Close,
			&b.Volume,
			&b.TickVolume,
			&b.IsOpen,
			&b.OpenTime,
			&b.Timestamp,
		)
		if err != nil {
			return nil, err
		}

		bars = append(bars, b)
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	return bars, nil
}

func (r *repository) SaveBars(
	ctx context.Context,
	symbol string,
	bars []model.Bar,
) error {
	query := `
        INSERT INTO bars (
            symbol,
            open,
			high,
			low,
			close,
			volume,
			tick_volume,
			is_open,
			open_time,
			timestamp
        )
        VALUES (
            $1, $2, $3, $4, $5, 
			$6, $7, $8, $9, $10
        )
		ON CONFLICT (symbol, open_time)
		DO UPDATE SET
			open = EXCLUDED.open,
			high = EXCLUDED.high,
			low = EXCLUDED.low,
			close = EXCLUDED.close,
			volume = EXCLUDED.volume,
			tick_volume = EXCLUDED.tick_volume,
			is_open = EXCLUDED.is_open,
			timestamp = EXCLUDED.timestamp
    `

	for i := len(bars) - 1; i >= 0; i-- {
		b := bars[i]

		_, err := r.psql.Exec(
			ctx,
			query,
			symbol,
			b.Open,
			b.High,
			b.Low,
			b.Close,
			b.Volume,
			b.TickVolume,
			b.IsOpen,
			b.OpenTime,
			time.Now(),
		)
		if err != nil {
			return err
		}
	}

	return nil
}

func (r *repository) GetLastOpenTime(
	ctx context.Context,
	symbol string,
) (*time.Time, error) {
	var last *time.Time

	err := r.psql.QueryRow(
		ctx,
		`
			SELECT MAX(open_time)
			FROM bars
			WHERE symbol = $1
        `,
		symbol,
	).Scan(&last)

	if err != nil {
		return nil, err
	}

	return last, nil
}
