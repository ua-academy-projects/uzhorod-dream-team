package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TEST_DATABASE_URL must identify a disposable database: PGMQ queues are reset.
func postgresTestStore(t *testing.T) *Store {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set TEST_DATABASE_URL to an isolated PostgreSQL test database")
	}
	ctx := context.Background()
	config, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal("invalid test database configuration")
	}
	schema := fmt.Sprintf("queue_test_%d", time.Now().UnixNano())
	config.ConnConfig.RuntimeParams["search_path"] = schema + ",public"
	config.ConnConfig.RuntimeParams["timezone"] = "UTC"
	config.ConnConfig.ConnectTimeout = 5 * time.Second
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		pool.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, err := pool.Exec(cleanup, "DROP SCHEMA "+schema+" CASCADE"); err != nil {
			t.Error(err)
		}
		pool.Close()
	})
	for _, name := range []string{"001_create_weather_snapshots.sql", "002_unique_weather_time.sql", "003_temperature_history.sql", "004_weather_jobs.sql", "005_postgres_queue.sql", "005_postgres_queue.sql"} {
		sql, err := os.ReadFile("../migrations/" + name)
		if err != nil {
			t.Fatal(err)
		}
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, string(sql)); err != nil {
			_ = tx.Rollback(ctx)
			t.Fatal(err)
		}
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := pool.Exec(ctx, "TRUNCATE pgmq.q_weather_requests, pgmq.q_weather_responses"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := pool.Exec(context.Background(), "TRUNCATE pgmq.q_weather_requests, pgmq.q_weather_responses"); err != nil {
			t.Error(err)
		}
	})
	return &Store{pool: pool, backend: backendPostgres}
}

func queueRequest(t *testing.T, kind string) WeatherRequest {
	t.Helper()
	id, err := newRequestID()
	if err != nil {
		t.Fatal(err)
	}
	return WeatherRequest{RequestID: id, Type: kind, City: "Uzhhorod", Latitude: 48.6167,
		Longitude: 22.3, ExpiresAt: time.Now().UTC().Add(time.Minute)}
}

func TestPostgresQueueAtomicSubmission(t *testing.T) {
	store := postgresTestStore(t)
	ctx := context.Background()
	collector := &Collector{store: store, jobs: store, config: Config{
		Backend: backendPostgres, City: "Uzhhorod", Latitude: 48.6167, Longitude: 22.3, JobTimeout: time.Minute}}
	job, err := collector.Collect(ctx) // No RabbitMQ publisher is installed.
	if err != nil {
		t.Fatal(err)
	}
	var published bool
	var backend string
	if err := store.pool.QueryRow(ctx, `SELECT published_at IS NOT NULL, backend FROM weather_jobs WHERE request_id=$1`, job.RequestID).Scan(&published, &backend); err != nil || !published || backend != backendPostgres {
		t.Fatalf("request was not atomically published: %v", err)
	}
	var count int
	if err := store.pool.QueryRow(ctx, "SELECT count(*) FROM pgmq.q_weather_requests WHERE message->>'request_id'=$1", job.RequestID).Scan(&count); err != nil || count != 1 {
		t.Fatalf("missing PostgreSQL request: count=%d, %v", count, err)
	}
	if _, err := store.pool.Exec(ctx, "ALTER TABLE pgmq.q_weather_requests ADD CONSTRAINT reject_temperature CHECK (message->>'type' <> 'temperature_history')"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = store.pool.Exec(context.Background(), "ALTER TABLE pgmq.q_weather_requests DROP CONSTRAINT IF EXISTS reject_temperature")
	})
	request := queueRequest(t, temperatureHistory)
	if _, err := store.CreateJob(ctx, request); err == nil {
		t.Fatal("expected enqueue failure")
	}
	if err := store.pool.QueryRow(ctx, "SELECT count(*) FROM weather_jobs WHERE request_id=$1", request.RequestID).Scan(&count); err != nil || count != 0 {
		t.Fatal("enqueue failure left an orphan job")
	}
	rabbitStore := &Store{pool: store.pool}
	if _, err := rabbitStore.CreateJob(ctx, request); err != nil {
		t.Fatal(err)
	}
	pending, err := rabbitStore.UnpublishedJobs(ctx)
	if err != nil || len(pending) != 1 || pending[0].RequestID != request.RequestID {
		t.Fatalf("backend publications were mixed: %+v, %v", pending, err)
	}
}

func TestPostgresResponseTransactionAndRedelivery(t *testing.T) {
	store := postgresTestStore(t)
	ctx := context.Background()
	request := queueRequest(t, currentWeather)
	if _, err := store.CreateJob(ctx, request); err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(WeatherResponse{RequestID: request.RequestID, Type: request.Type,
		Status: "completed", Data: json.RawMessage(validWeather)})
	enqueue := func() {
		t.Helper()
		if _, err := store.pool.Exec(ctx, "SELECT pgmq.send('weather_responses', $1::jsonb)", body); err != nil {
			t.Fatal(err)
		}
	}
	enqueue()
	if _, err := store.pool.Exec(ctx, "ALTER TABLE weather_snapshots ADD CONSTRAINT reject_snapshot CHECK (false)"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.consumePostgresResponse(ctx); err == nil {
		t.Fatal("expected snapshot transaction failure")
	}
	job, err := store.GetJob(ctx, request.RequestID)
	if err != nil || job.Status != "queued" {
		t.Fatal("failed transaction completed the job")
	}
	var responses int
	if err := store.pool.QueryRow(ctx, "SELECT count(*) FROM pgmq.q_weather_responses").Scan(&responses); err != nil || responses != 1 {
		t.Fatal("failed transaction acknowledged the response")
	}
	if _, err := store.pool.Exec(ctx, "ALTER TABLE weather_snapshots DROP CONSTRAINT reject_snapshot"); err != nil {
		t.Fatal(err)
	}
	lock, err := store.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Rollback(ctx)
	if _, err := lock.Exec(ctx, "SELECT msg_id FROM pgmq.q_weather_responses FOR UPDATE"); err != nil {
		t.Fatal(err)
	}
	if consumed, err := store.consumePostgresResponse(ctx); err != nil || consumed {
		t.Fatal("consumer did not skip a locked response")
	}
	if err := lock.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	var workers sync.WaitGroup
	consumed := make(chan bool, 2)
	errors := make(chan error, 2)
	for range 2 {
		workers.Add(1)
		go func() {
			defer workers.Done()
			ok, err := store.consumePostgresResponse(ctx)
			consumed <- ok
			errors <- err
		}()
	}
	workers.Wait()
	if err1, err2 := <-errors, <-errors; err1 != nil || err2 != nil {
		t.Fatalf("concurrent consumption: %v, %v", err1, err2)
	}
	if first, second := <-consumed, <-consumed; first == second {
		t.Fatal("one response must be consumed exactly once")
	}
	job, err = store.GetJob(ctx, request.RequestID)
	if err != nil || job.Status != "completed" {
		t.Fatal("response did not complete the job")
	}
	first, err := store.Latest(ctx)
	if err != nil {
		t.Fatal(err)
	}
	enqueue()
	if consumed, err := store.consumePostgresResponse(ctx); err != nil || !consumed {
		t.Fatalf("redelivery: %v", err)
	}
	latest, err := store.Latest(ctx)
	if err != nil || latest.ID != first.ID || !latest.FetchedAt.Equal(first.FetchedAt) {
		t.Fatal("redelivery changed the saved snapshot")
	}
}

func TestPostgresQueueExpiryAndMalformedResponse(t *testing.T) {
	store := postgresTestStore(t)
	ctx := context.Background()
	request := queueRequest(t, currentWeather)
	if _, err := store.CreateJob(ctx, request); err != nil {
		t.Fatal(err)
	}
	if _, err := store.pool.Exec(ctx, `SELECT pgmq.send('weather_responses', '{"request_id":"mismatched"}'::jsonb)`); err != nil {
		t.Fatal(err)
	}
	if consumed, err := store.consumePostgresResponse(ctx); err != nil || !consumed {
		t.Fatal("malformed response was not discarded")
	}
	if _, err := store.pool.Exec(ctx, "UPDATE weather_jobs SET expires_at=NOW()-INTERVAL '1 second'"); err != nil {
		t.Fatal(err)
	}
	if err := store.ExpireJobs(ctx); err != nil {
		t.Fatal(err)
	}
	job, err := store.GetJob(ctx, request.RequestID)
	if err != nil || job.Status != "failed" || job.Error.Code != "job_expired" {
		t.Fatal("expired job was not failed")
	}
	var remaining int
	if err := store.pool.QueryRow(ctx, "SELECT (SELECT count(*) FROM pgmq.q_weather_requests)+(SELECT count(*) FROM pgmq.q_weather_responses)").Scan(&remaining); err != nil || remaining != 0 {
		t.Fatal("expired messages were not removed")
	}
}
