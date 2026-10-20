package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/joho/godotenv"
	"github.com/rabbitmq/amqp091-go"

	"data-monitor/history/internal/database"
	"data-monitor/history/internal/fetcher"
	"data-monitor/history/internal/models"
	"data-monitor/history/internal/server"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	if err := godotenv.Load(".env"); err != nil {
		if parentErr := godotenv.Load("../.env"); parentErr != nil {
			logger.Warn("could not load .env", "error", parentErr)
		}
	}

	ctx, cancel := signal.NotifyContext(
		context.Background(),
		syscall.SIGINT,
		syscall.SIGTERM,
	)
	defer cancel()

	backend := env("APP_BACKEND", "hybrid")
	if backend != "hybrid" && backend != "postgres" {
		logger.Error("invalid APP_BACKEND: expected hybrid or postgres")
		os.Exit(2)
	}

	dsn := fmt.Sprintf(
		"host=%s port=%s dbname=%s user=%s password=%s sslmode=disable",
		env("POSTGRES_HOST", "192.168.56.13"),
		env("POSTGRES_PORT", "5432"),
		env("POSTGRES_DB", "history"),
		env("POSTGRES_USER", "postgres"),
		env("POSTGRES_PASSWORD", "postgres"),
	)

	var db *database.Store

	for attempt := 0; ; attempt++ {
		if ctx.Err() != nil {
			return
		}

		connectCtx, done := context.WithTimeout(ctx, 5*time.Second)
		var err error

		db, err = database.Connect(connectCtx, dsn)
		done()

		if err == nil {
			break
		}

		logger.Error(
			"database connection failed",
			"error", err,
			"attempt", attempt+1,
		)

		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff(attempt)):
		}
	}

	defer db.Pool.Close()

	initCtx, initDone := context.WithTimeout(ctx, 15*time.Second)
	if err := db.EnsureFetcherRole(initCtx, os.Getenv("FETCHER_POSTGRES_PASSWORD")); err != nil {
		initDone()
		logger.Error("fetcher database role configuration failed", "error", err)
		return
	}
	err := db.Init(initCtx, backend == "postgres")
	initDone()

	if err != nil {
		logger.Error("database initialization failed", "error", err)
		return
	}

	interval := durationSeconds("HISTORY_INTERVAL_SECONDS", 10)

	rabbitURL := env(
		"RABBITMQ_URL",
		"amqp://datamonitor:datamonitor@192.168.56.13:5672/",
	)

	sample := func() {
		requestCtx, done := context.WithTimeout(ctx, 30*time.Second)
		defer done()

		logger.Info("requesting current data from fetcher")

		var items []models.Current
		var err error
		if backend == "hybrid" {
			items, err = requestRabbit(requestCtx, rabbitURL)
			if err != nil {
				logger.Warn("RabbitMQ request failed; using PostgreSQL task fallback", "error", err)
				items, err = requestPostgresFallback(requestCtx, db)
			}
		} else {
			logger.Warn(
				"requesting data through PostgreSQL queue",
			)
			items, err = requestPostgresFallback(requestCtx, db)
		}

		if err != nil {
			logger.Error("failed to obtain current data", "error", err)
			return
		}

		for _, item := range items {
			if item.Timestamp.IsZero() {
				logger.Error(
					"fetcher returned an item without a timestamp",
					"source", item.Source,
				)
				continue
			}

			if err := db.Insert(
				requestCtx,
				item.Source,
				item.Value,
				item.Timestamp,
			); err != nil {
				logger.Error(
					"failed to save history",
					"source", item.Source,
					"error", err,
				)
				continue
			}

			logger.Info(
				"saved history record",
				"source", item.Source,
				"value", item.Value,
			)
		}
	}

	go func() {
		sample()

		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				sample()
			}
		}
	}()

	port := env("PORT", "8000")

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           server.API{DB: db}.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		<-ctx.Done()

		shutdownCtx, done := context.WithTimeout(
			context.Background(),
			5*time.Second,
		)
		defer done()

		_ = srv.Shutdown(shutdownCtx)
	}()

	logger.Info("history service started", "port", port)

	if err := srv.ListenAndServe(); err != nil &&
		err != http.ErrServerClosed {
		logger.Error("http server failed", "error", err)
		os.Exit(1)
	}
}

func requestRabbit(
	ctx context.Context,
	rabbitURL string,
) ([]models.Current, error) {
	rabbit, err := amqp091.Dial(rabbitURL)
	if err != nil {
		return nil, err
	}
	defer rabbit.Close()

	channel, err := rabbit.Channel()
	if err != nil {
		return nil, err
	}
	defer channel.Close()

	_, err = channel.QueueDeclare(
		fetcher.RequestQueue,
		true,
		false,
		false,
		false,
		nil,
	)
	if err != nil {
		return nil, err
	}

	client := fetcher.Client{Channel: channel}
	return client.All(ctx)
}

func requestPostgresFallback(
	ctx context.Context,
	db *database.Store,
) ([]models.Current, error) {
	id, err := db.CreateFetcherTask(ctx)
	if err != nil {
		return nil, fmt.Errorf("create fallback task: %w", err)
	}

	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()

	for {
		status, items, taskError, err := db.GetFetcherTask(ctx, id)
		if err != nil {
			return nil, fmt.Errorf("read fallback task: %w", err)
		}

		switch status {
		case "completed":
			return items, nil
		case "failed":
			return nil, fmt.Errorf("fetcher task failed: %s", taskError)
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ticker.C:
		}
	}
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func durationSeconds(key string, fallback int) time.Duration {
	value, err := strconv.Atoi(os.Getenv(key))
	if err != nil || value < 1 {
		value = fallback
	}

	return time.Duration(value) * time.Second
}

func backoff(attempt int) time.Duration {
	return time.Duration(1<<min(attempt, 5)) * time.Second
}
