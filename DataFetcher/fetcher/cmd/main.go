package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/joho/godotenv"
	"github.com/rabbitmq/amqp091-go"

	"data-monitor/fetcher/internal/client"
	"data-monitor/fetcher/internal/server"
)

type source struct {
	Name string
	URL  string
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	if err := godotenv.Load(".env"); err != nil {
		if parentErr := godotenv.Load("../.env"); parentErr != nil {
			logger.Warn("could not load .env", "error", parentErr.Error())
		}
	}

	sources := parseSources(os.Getenv("SOURCES"))
	if len(sources) == 0 {
		sources = defaultSources()
	}

	ctx, cancel := signal.NotifyContext(
		context.Background(),
		syscall.SIGINT,
		syscall.SIGTERM,
	)
	defer cancel()

	store := server.NewStore()
	backend := env("APP_BACKEND", "hybrid")
	if backend != "hybrid" && backend != "postgres" {
		logger.Error("invalid APP_BACKEND: expected hybrid or postgres")
		os.Exit(2)
	}

	rabbitURL := env(
		"RABBITMQ_URL",
		"amqp://datamonitor:datamonitor@192.168.56.13:5672/",
	)

	if backend == "hybrid" {
		go runRabbitConsumerLoop(ctx, logger, rabbitURL, sources, store)
	}

	// Fallback communication mechanism: PostgreSQL task queue.
	pgHost := env("FETCHER_POSTGRES_HOST", "192.168.56.13")
	pgPort := env("FETCHER_POSTGRES_PORT", "5432")
	pgDB := env("FETCHER_POSTGRES_DB", "history")
	pgUser := env("FETCHER_POSTGRES_USER", "fetcher_worker")
	pgPassword := os.Getenv("FETCHER_POSTGRES_PASSWORD")

	if backend == "postgres" && pgPassword == "" {
		logger.Error("FETCHER_POSTGRES_PASSWORD is required when APP_BACKEND=postgres")
		os.Exit(2)
	}
	if backend == "postgres" {
		dsn := fmt.Sprintf("host=%s port=%s dbname=%s user=%s password=%s sslmode=disable", pgHost, pgPort, pgDB, pgUser, pgPassword)
		go runPostgresFallbackLoop(ctx, logger, dsn, sources, store, true)
	} else if pgPassword == "" {
		logger.Error(
			"PostgreSQL fallback disabled: FETCHER_POSTGRES_PASSWORD is empty",
		)
	} else {
		dsn := fmt.Sprintf(
			"host=%s port=%s dbname=%s user=%s password=%s sslmode=disable",
			pgHost,
			pgPort,
			pgDB,
			pgUser,
			pgPassword,
		)

		go runPostgresFallbackLoop(ctx, logger, dsn, sources, store, false)
	}

	port := env("FETCHER_PORT", "8000")

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           server.Handler(store),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		<-ctx.Done()

		shutdownCtx, shutdownCancel := context.WithTimeout(
			context.Background(),
			5*time.Second,
		)
		defer shutdownCancel()

		_ = srv.Shutdown(shutdownCtx)
	}()

	logger.Info(
		"fetcher service started",
		"port", port,
		"sources", len(sources),
	)

	if err := srv.ListenAndServe(); err != nil &&
		err != http.ErrServerClosed {
		logger.Error("http server failed", "error", err)
		os.Exit(1)
	}
}

// runPostgresFallbackLoop continuously polls PostgreSQL for pending tasks.
// It reconnects when PostgreSQL becomes temporarily unavailable.
func runPostgresFallbackLoop(
	ctx context.Context,
	logger *slog.Logger,
	dsn string,
	sources []source,
	store *server.Store,
	usePGMQ bool,
) {
	for attempt := 0; ctx.Err() == nil; attempt++ {
		pool, err := pgxpool.New(ctx, dsn)

		if err == nil {
			pingCtx, pingCancel := context.WithTimeout(
				ctx,
				5*time.Second,
			)
			err = pool.Ping(pingCtx)
			pingCancel()
		}

		if err != nil {
			if pool != nil {
				pool.Close()
			}

			logger.Error(
				"PostgreSQL fallback connection failed",
				"error", err,
				"attempt", attempt+1,
			)

			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff(attempt)):
			}
			continue
		}

		logger.Info("PostgreSQL fallback worker ready")
		attempt = 0

		disconnected := false

		for ctx.Err() == nil {
			var taskID int64
			var messageID int64
			var readCount int

			// Atomically claim one task so that multiple workers
			// cannot process the same task concurrently.
			var err error
			if usePGMQ {
				var message []byte
				err = pool.QueryRow(ctx, `SELECT msg_id, message, read_ct FROM pgmq.read('fetcher_tasks', 60, 1)`).Scan(&messageID, &message, &readCount)
				if err == nil {
					var payload struct {
						TaskID int64 `json:"task_id"`
					}
					err = json.Unmarshal(message, &payload)
					taskID = payload.TaskID
					if err == nil && taskID <= 0 {
						err = fmt.Errorf("invalid task_id in PGMQ message")
					}
				}
			} else {
				err = pool.QueryRow(ctx, `
				WITH next_task AS (
					SELECT id
					FROM fetcher_tasks
					WHERE status = 'pending'
					   OR (
						   status = 'processing'
						   AND updated_at < NOW() - INTERVAL '60 seconds'
					   )
					ORDER BY id
					LIMIT 1
					FOR UPDATE SKIP LOCKED
				)
				UPDATE fetcher_tasks AS task
				SET status = 'processing',
					updated_at = NOW(),
					error = NULL
				FROM next_task
				WHERE task.id = next_task.id
				RETURNING task.id
				`).Scan(&taskID)
			}

			if err != nil && err != pgx.ErrNoRows {
				logger.Error(
					"failed to claim PostgreSQL task",
					"error", err,
				)
				disconnected = true
				break
			}

			if err == pgx.ErrNoRows {
				select {
				case <-ctx.Done():
					pool.Close()
					return
				case <-time.After(time.Second):
				}
				continue
			}
			if err != nil {
				logger.Error("invalid PGMQ task payload", "error", err, "message_id", messageID)
				if _, archiveErr := pool.Exec(ctx, `SELECT pgmq.archive('fetcher_tasks'::text, $1::bigint)`, messageID); archiveErr != nil {
					logger.Error("failed to archive invalid PGMQ payload", "message_id", messageID, "error", archiveErr)
					disconnected = true
					break
				}
				continue
			}
			if usePGMQ {
				var taskStatus string
				if err = pool.QueryRow(ctx, `SELECT status FROM fetcher_tasks WHERE id=$1`, taskID).Scan(&taskStatus); err != nil {
					if err == pgx.ErrNoRows {
						logger.Error("PGMQ message references a missing task; archiving", "task_id", taskID, "message_id", messageID)
						if _, archiveErr := pool.Exec(ctx, `SELECT pgmq.archive('fetcher_tasks'::text, $1::bigint)`, messageID); archiveErr != nil {
							logger.Error("failed to archive PGMQ message with missing task", "message_id", messageID, "error", archiveErr)
							disconnected = true
							break
						}
						continue
					}
					logger.Error("failed to inspect task state", "task_id", taskID, "error", err)
					disconnected = true
					break
				}
				if taskStatus == "completed" {
					if _, err = pool.Exec(ctx, `SELECT pgmq.delete('fetcher_tasks'::text, $1::bigint)`, messageID); err != nil {
						logger.Error("failed to acknowledge already completed task", "task_id", taskID, "error", err)
						disconnected = true
						break
					}
					continue
				}
				if _, err = pool.Exec(ctx, `UPDATE fetcher_tasks SET status='processing', updated_at=NOW(), error=NULL WHERE id=$1`, taskID); err != nil {
					logger.Error("failed to mark PGMQ task processing", "task_id", taskID, "error", err)
					disconnected = true
					break
				}
			}

			logger.Info(
				"processing PostgreSQL fallback task",
				"task_id", taskID,
			)

			taskCtx, taskCancel := context.WithTimeout(
				ctx,
				30*time.Second,
			)

			items := make([]server.Item, 0, len(sources))

			for _, src := range sources {
				api := client.External{
					URL:  src.URL,
					HTTP: &http.Client{Timeout: 10 * time.Second},
				}

				value, fetchErr := api.Fetch(taskCtx)
				if fetchErr != nil {
					logger.Error(
						"fallback fetch failed",
						"source", src.Name,
						"error", fetchErr,
					)
					continue
				}

				store.Set(src.Name, value)

				items = append(items, server.Item{
					Source:    src.Name,
					Value:     value,
					Timestamp: time.Now().UTC(),
				})
			}

			taskCancel()

			if ctx.Err() != nil {
				pool.Close()
				return
			}

			if len(items) == 0 {
				_, err = pool.Exec(ctx, `
					UPDATE fetcher_tasks
					SET status = 'failed',
						error = $2,
						updated_at = NOW()
					WHERE id = $1
				`, taskID, "no source returned valid data")
			} else {
				var raw []byte
				raw, err = json.Marshal(items)

				if err == nil {
					_, err = pool.Exec(ctx, `
						UPDATE fetcher_tasks
						SET status = 'completed',
							result = $2::jsonb,
							error = NULL,
							updated_at = NOW()
						WHERE id = $1
					`, taskID, string(raw))
				}
			}

			if err != nil {
				logger.Error(
					"failed to save fallback task result",
					"task_id", taskID,
					"error", err,
				)
				disconnected = true
				break
			}
			if usePGMQ && len(items) > 0 {
				if _, err = pool.Exec(ctx, `SELECT pgmq.delete('fetcher_tasks'::text, $1::bigint)`, messageID); err != nil {
					logger.Error("failed to acknowledge PGMQ task", "message_id", messageID, "error", err)
					disconnected = true
					break
				}
			} else if usePGMQ && readCount >= 5 {
				if _, err = pool.Exec(ctx, `SELECT pgmq.archive('fetcher_tasks'::text, $1::bigint)`, messageID); err != nil {
					logger.Error("failed to archive exhausted PGMQ task", "message_id", messageID, "error", err)
					disconnected = true
					break
				}
			}

			logger.Info(
				"PostgreSQL fallback task completed",
				"task_id", taskID,
				"items", len(items),
			)
		}

		pool.Close()

		if ctx.Err() != nil {
			return
		}

		if disconnected {
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff(attempt)):
			}
		}
	}
}

func serveRequests(
	ctx context.Context,
	logger *slog.Logger,
	channel *amqp091.Channel,
	requests <-chan amqp091.Delivery,
	sources []source,
	store *server.Store,
) {
	for {
		select {
		case <-ctx.Done():
			return

		case delivery, ok := <-requests:
			if !ok {
				return
			}

			items := make([]server.Item, 0, len(sources))

			for _, src := range sources {
				api := client.External{
					URL:  src.URL,
					HTTP: &http.Client{Timeout: 10 * time.Second},
				}

				value, err := api.Fetch(ctx)
				if err != nil {
					logger.Error(
						"queued external API request failed",
						"source", src.Name,
						"error", err,
					)
					continue
				}

				store.Set(src.Name, value)

				items = append(items, server.Item{
					Source:    src.Name,
					Value:     value,
					Timestamp: time.Now().UTC(),
				})
			}

			body, err := json.Marshal(struct {
				Data  []server.Item `json:"data"`
				Error string        `json:"error,omitempty"`
			}{
				Data: items,
			})

			if err != nil {
				logger.Error("failed to encode fetch response", "error", err)
				_ = delivery.Nack(false, true)
				continue
			}

			if len(items) == 0 {
				body, err = json.Marshal(map[string]string{
					"error": "no source returned valid data",
				})
				if err != nil {
					logger.Error("failed to encode error response", "error", err)
					_ = delivery.Nack(false, true)
					continue
				}
			}

			if delivery.ReplyTo != "" {
				if err := channel.PublishWithContext(
					ctx,
					"",
					delivery.ReplyTo,
					false,
					false,
					amqp091.Publishing{
						ContentType:   "application/json",
						CorrelationId: delivery.CorrelationId,
						Body:          body,
					},
				); err != nil {
					logger.Error("failed to publish fetch reply", "error", err)
					_ = delivery.Nack(false, true)
					continue
				}
			}

			if err := delivery.Ack(false); err != nil {
				logger.Error("failed to acknowledge request", "error", err)
			}
		}
	}
}

func runRabbitConsumerLoop(
	ctx context.Context,
	logger *slog.Logger,
	rabbitURL string,
	sources []source,
	store *server.Store,
) {
	for attempt := 0; ctx.Err() == nil; attempt++ {
		conn, err := amqp091.Dial(rabbitURL)
		if err != nil {
			logger.Error(
				"RabbitMQ connection failed",
				"error", err,
				"attempt", attempt+1,
			)

			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff(attempt)):
			}
			continue
		}

		channel, err := conn.Channel()
		if err != nil {
			logger.Error("RabbitMQ channel failed", "error", err)
			_ = conn.Close()

			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff(attempt)):
			}
			continue
		}

		_, err = channel.QueueDeclare(
			"fetcher.requests",
			true,
			false,
			false,
			false,
			nil,
		)
		if err != nil {
			logger.Error("RabbitMQ queue declaration failed", "error", err)
			_ = channel.Close()
			_ = conn.Close()

			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff(attempt)):
			}
			continue
		}

		if err = channel.Qos(1, 0, false); err != nil {
			logger.Error("RabbitMQ qos failed", "error", err)
			_ = channel.Close()
			_ = conn.Close()

			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff(attempt)):
			}
			continue
		}

		requests, err := channel.Consume(
			"fetcher.requests",
			"",
			false,
			false,
			false,
			false,
			nil,
		)
		if err != nil {
			logger.Error("RabbitMQ consumer failed", "error", err)
			_ = channel.Close()
			_ = conn.Close()

			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff(attempt)):
			}
			continue
		}

		logger.Info("RabbitMQ consumer ready")

		serveRequests(ctx, logger, channel, requests, sources, store)

		_ = channel.Close()
		_ = conn.Close()

		if ctx.Err() != nil {
			return
		}

		logger.Warn("RabbitMQ consumer stopped; reconnecting")

		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff(attempt)):
		}
	}
}

func defaultSources() []source {
	return []source{
		{
			Name: "btc",
			URL:  "https://api.coinbase.com/v2/prices/BTC-USD/spot",
		},
		{
			Name: "eth",
			URL:  "https://api.coinbase.com/v2/prices/ETH-USD/spot",
		},
	}
}

func parseSources(raw string) []source {
	var out []source

	for _, part := range strings.Split(raw, ",") {
		name, url, ok := strings.Cut(strings.TrimSpace(part), "=")

		if !ok {
			continue
		}

		name = strings.Trim(strings.TrimSpace(name), `"'`)
		url = strings.Trim(strings.TrimSpace(url), `"'`)

		if name == "" || url == "" {
			continue
		}

		out = append(out, source{
			Name: name,
			URL:  url,
		})
	}

	return out
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func backoff(attempt int) time.Duration {
	return time.Duration(1<<min(attempt, 5)) * time.Second
}
