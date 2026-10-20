package database

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"data-monitor/history/internal/models"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Store struct {
	Pool *pgxpool.Pool
	PGMQ bool
}

func Connect(ctx context.Context, dsn string) (*Store, error) {
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, err
	}

	if err = pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}

	return &Store{Pool: pool}, nil
}

func (s *Store) Init(ctx context.Context, usePGMQ bool) error {
	statements := []string{
		`
		CREATE EXTENSION IF NOT EXISTS hstore
		`,
		`
		CREATE TABLE IF NOT EXISTS history (
			id BIGSERIAL PRIMARY KEY,
			source TEXT NOT NULL DEFAULT 'btc',
			value DOUBLE PRECISION NOT NULL,
			recorded_at TIMESTAMPTZ NOT NULL
		)
		`,
		`
		ALTER TABLE history
		ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'btc'
		`,
		`
		CREATE INDEX IF NOT EXISTS idx_history_source_time
		ON history (source, recorded_at DESC)
		`,
		`
		UPDATE history
		SET source = trim(BOTH '"' FROM source)
		WHERE (source LIKE '"%' OR source LIKE '%"')
		  AND trim(BOTH '"' FROM source) <> ''
		`,
		`
		CREATE TABLE IF NOT EXISTS fetcher_tasks (
			id BIGSERIAL PRIMARY KEY,
			status TEXT NOT NULL DEFAULT 'pending'
				CHECK (
					status IN (
						'pending',
						'processing',
						'completed',
						'failed'
					)
				),
			result JSONB,
			error TEXT,
			queue_enqueued BOOLEAN NOT NULL DEFAULT FALSE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)
		`,
		`ALTER TABLE fetcher_tasks ADD COLUMN IF NOT EXISTS queue_enqueued BOOLEAN NOT NULL DEFAULT FALSE`,
		`
		CREATE INDEX IF NOT EXISTS idx_fetcher_tasks_pending
		ON fetcher_tasks (id)
		WHERE status = 'pending'
		`,
		`
		CREATE TABLE IF NOT EXISTS user_preferences (
			session_id TEXT PRIMARY KEY,
			preferences HSTORE NOT NULL,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)
		`,
		`GRANT CONNECT ON DATABASE history TO fetcher_worker`,
		`GRANT USAGE ON SCHEMA public TO fetcher_worker`,
		`
		GRANT SELECT (id, status, updated_at)
		ON TABLE fetcher_tasks TO fetcher_worker
		`,
		`
		GRANT UPDATE (status, result, error, updated_at)
		ON TABLE fetcher_tasks TO fetcher_worker
		`,
	}
	if usePGMQ {
		statements = append([]string{
			`CREATE EXTENSION IF NOT EXISTS pgmq`,
			`DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pgmq.meta WHERE queue_name = 'fetcher_tasks') THEN PERFORM pgmq.create('fetcher_tasks'); END IF; END $$`,
			`GRANT USAGE ON SCHEMA pgmq TO fetcher_worker`,
			`GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pgmq.q_fetcher_tasks, pgmq.a_fetcher_tasks TO fetcher_worker`,
			`GRANT USAGE, SELECT ON SEQUENCE pgmq.q_fetcher_tasks_msg_id_seq TO fetcher_worker`,
			`GRANT EXECUTE ON FUNCTION pgmq.read(TEXT, INTEGER, INTEGER, JSONB) TO fetcher_worker`,
			`GRANT EXECUTE ON FUNCTION pgmq.delete(TEXT, BIGINT) TO fetcher_worker`,
			`GRANT EXECUTE ON FUNCTION pgmq.archive(TEXT, BIGINT) TO fetcher_worker`,
		}, statements...)
		s.PGMQ = true
		statements = append(statements, `WITH pending AS (
			UPDATE fetcher_tasks SET queue_enqueued=TRUE, status='pending', updated_at=NOW()
			WHERE queue_enqueued=FALSE AND status IN ('pending','processing')
			RETURNING id
		) SELECT pgmq.send('fetcher_tasks', jsonb_build_object('task_id', id)) FROM pending`)
	}

	for _, statement := range statements {
		if _, err := s.Pool.Exec(ctx, statement); err != nil {
			return fmt.Errorf(
				"database initialization failed: %w",
				err,
			)
		}
	}

	return nil
}

func (s *Store) EnsureFetcherRole(ctx context.Context, password string) error {
	if password == "" {
		return fmt.Errorf("FETCHER_POSTGRES_PASSWORD is required to configure fetcher_worker")
	}
	var exists bool
	if err := s.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='fetcher_worker')`).Scan(&exists); err != nil {
		return err
	}
	verb := "CREATE"
	if exists {
		verb = "ALTER"
	}
	var ddl string
	if err := s.Pool.QueryRow(ctx, `SELECT format($q$`+verb+` ROLE fetcher_worker LOGIN PASSWORD %L$q$, $1::text)`, password).Scan(&ddl); err != nil {
		return err
	}
	_, err := s.Pool.Exec(ctx, ddl)
	return err
}

func (s *Store) Insert(
	ctx context.Context,
	source string,
	value float64,
	at time.Time,
) error {
	_, err := s.Pool.Exec(ctx, `
		INSERT INTO history (source, value, recorded_at)
		VALUES ($1, $2, $3)
	`, source, value, at.UTC())

	return err
}

func (s *Store) List(
	ctx context.Context,
	source string,
	limit int,
	from, to *time.Time,
) ([]models.Record, error) {
	if limit < 1 {
		return nil, fmt.Errorf("limit must be positive")
	}

	rows, err := s.Pool.Query(ctx, `
		SELECT id, source, value, recorded_at
		FROM history
		WHERE source = $1
		  AND ($2::timestamptz IS NULL OR recorded_at >= $2)
		  AND ($3::timestamptz IS NULL OR recorded_at <= $3)
		ORDER BY recorded_at DESC
		LIMIT $4
	`, source, from, to, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	records := make([]models.Record, 0)

	for rows.Next() {
		var record models.Record

		if err := rows.Scan(
			&record.ID,
			&record.Source,
			&record.Value,
			&record.RecordedAt,
		); err != nil {
			return nil, err
		}

		record.RecordedAt = record.RecordedAt.UTC()
		records = append(records, record)
	}

	return records, rows.Err()
}

func (s *Store) Sources(ctx context.Context) ([]string, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT DISTINCT source
		FROM history
		ORDER BY source
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	sources := make([]string, 0)

	for rows.Next() {
		var name string

		if err := rows.Scan(&name); err != nil {
			return nil, err
		}

		sources = append(sources, name)
	}

	return sources, rows.Err()
}

func (s *Store) CreateFetcherTask(ctx context.Context) (int64, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	var id int64
	err = tx.QueryRow(ctx, `
		INSERT INTO fetcher_tasks (status)
		VALUES ('pending')
		RETURNING id
	`).Scan(&id)
	if err != nil {
		return 0, err
	}
	if s.PGMQ {
		var messageID int64
		if err = tx.QueryRow(ctx, `SELECT pgmq.send('fetcher_tasks', jsonb_build_object('task_id', $1::bigint))`, id).Scan(&messageID); err != nil {
			return 0, err
		}
		if _, err = tx.Exec(ctx, `UPDATE fetcher_tasks SET queue_enqueued=TRUE WHERE id=$1`, id); err != nil {
			return 0, err
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return 0, err
	}
	return id, nil
}

func (s *Store) GetFetcherTask(
	ctx context.Context,
	id int64,
) (string, []models.Current, string, error) {
	var status string
	var raw []byte
	var taskError string

	err := s.Pool.QueryRow(ctx, `
		SELECT status, result, COALESCE(error, '')
		FROM fetcher_tasks
		WHERE id = $1
	`, id).Scan(&status, &raw, &taskError)
	if err != nil {
		return "", nil, "", err
	}

	var items []models.Current

	if status == "completed" {
		if err := json.Unmarshal(raw, &items); err != nil {
			return "", nil, "", fmt.Errorf(
				"decode fetcher task result: %w", err,
			)
		}
	}

	return status, items, taskError, nil
}

func (s *Store) SavePreferences(
	ctx context.Context,
	sessionID string,
	preferences map[string]string,
) error {
	keys := make([]string, 0, len(preferences))
	for key := range preferences {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	pairs := make([]string, 0, len(preferences)*2)
	for _, key := range keys {
		pairs = append(pairs, key, preferences[key])
	}

	_, err := s.Pool.Exec(ctx, `
		INSERT INTO user_preferences (session_id, preferences)
		VALUES ($1, hstore($2::text[]))
		ON CONFLICT (session_id)
		DO UPDATE SET
			preferences = EXCLUDED.preferences,
			updated_at = NOW()
	`, sessionID, pairs)

	return err
}

func (s *Store) GetPreferences(
	ctx context.Context,
	sessionID string,
) (map[string]string, bool, error) {
	var raw []byte

	err := s.Pool.QueryRow(ctx, `
		SELECT hstore_to_jsonb(preferences)
		FROM user_preferences
		WHERE session_id = $1
		  AND updated_at > NOW() - INTERVAL '30 days'
	`, sessionID).Scan(&raw)

	if err != nil {
		if err == pgx.ErrNoRows {
			return nil, false, nil
		}

		return nil, false, err
	}

	var preferences map[string]string

	if err := json.Unmarshal(raw, &preferences); err != nil {
		return nil, false, err
	}

	return preferences, true, nil
}
