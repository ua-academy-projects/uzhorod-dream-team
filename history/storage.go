package main

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// executor runs one SQL command. Both the pool of connections (*pgxpool.Pool) and
// a transaction (pgx.Tx) have this method, so saveRecord works with either of them.
type executor interface {
	Exec(ctx context.Context, sql string, arguments ...any) (pgconn.CommandTag, error)
}

// connectDB connects to PostgreSQL and checks the connection right away.
func connectDB(ctx context.Context, databaseURL string) (*pgxpool.Pool, error) {
	db, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return nil, fmt.Errorf("неправильний DATABASE_URL: %w", err)
	}

	// pgxpool.New does not connect to the database yet, so we check with Ping.
	if err := db.Ping(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("не вдалося підключитися до бази: %w", err)
	}

	return db, nil
}

// saveRecord stores a measurement.
// It returns true if the row was inserted and false if it already existed (a duplicate).
// db is the pool (mode rabbitmq) or the transaction of the response (mode postgres).
func saveRecord(ctx context.Context, db executor, record WeatherRecord) (bool, error) {
	// $1, $2... are placeholders for values. pgx fills them in safely (protection against SQL injection).
	result, err := db.Exec(ctx, `
		INSERT INTO weather_records (city, temperature_c, observed_at, fetched_at)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (city, observed_at) DO NOTHING`,
		record.City, record.TemperatureC, record.ObservedAt, record.FetchedAt,
	)
	if err != nil {
		return false, fmt.Errorf("запис у базу: %w", err)
	}

	return result.RowsAffected() == 1, nil
}

// latestRecords returns the latest 100 measurements, from newest to oldest.
func latestRecords(ctx context.Context, db *pgxpool.Pool) ([]WeatherRecord, error) {
	rows, err := db.Query(ctx, `
		SELECT city, temperature_c, observed_at, fetched_at
		FROM weather_records
		ORDER BY observed_at DESC
		LIMIT 100`)
	if err != nil {
		return nil, fmt.Errorf("читання історії з бази: %w", err)
	}
	defer rows.Close()

	records := make([]WeatherRecord, 0)
	for rows.Next() {
		var record WeatherRecord
		if err := rows.Scan(
			&record.City,
			&record.TemperatureC,
			&record.ObservedAt,
			&record.FetchedAt,
		); err != nil {
			return nil, fmt.Errorf("читання запису історії: %w", err)
		}
		record.ObservedAt = record.ObservedAt.UTC()
		record.FetchedAt = record.FetchedAt.UTC()
		records = append(records, record)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("читання історії з бази: %w", err)
	}

	return records, nil
}
