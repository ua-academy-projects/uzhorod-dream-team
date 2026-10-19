package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"weather-history/internal/api"
	"weather-history/internal/app"
	"weather-history/internal/config"
	"weather-history/internal/domain"
	"weather-history/internal/messaging/rabbitmq"
	"weather-history/internal/storage/postgres"
	rediscache "weather-history/internal/storage/redis"
)

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	dbConfig, err := pgxpool.ParseConfig(cfg.DatabaseURL)
	if err != nil {
		return fmt.Errorf("invalid DATABASE_URL (check PostgreSQL URL format)")
	}
	dbConfig.ConnConfig.RuntimeParams["timezone"] = "UTC"
	dbConfig.ConnConfig.ConnectTimeout = 5 * time.Second
	pool, err := pgxpool.NewWithConfig(ctx, dbConfig)
	if err != nil {
		return fmt.Errorf("create PostgreSQL pool: %w", err)
	}
	defer pool.Close()
	store := postgres.New(pool, cfg.Backend)
	if err := store.Ping(ctx); err != nil {
		return fmt.Errorf("connect PostgreSQL: %w", err)
	}
	checkCtx, checkCancel := context.WithTimeout(ctx, 5*time.Second)
	_, err = pool.Exec(checkCtx, "SELECT "+postgres.Columns+" FROM weather_snapshots LIMIT 0")
	checkCancel()
	if err != nil {
		return fmt.Errorf("check weather_snapshots: apply infra/postgres/migrations/001_create_weather_snapshots.sql: %w", err)
	}
	checkCtx, checkCancel = context.WithTimeout(ctx, 5*time.Second)
	_, err = pool.Exec(checkCtx, "SELECT city, weather_time, temperature_c FROM temperature_history LIMIT 0")
	checkCancel()
	if err != nil {
		return fmt.Errorf("check temperature_history: apply infra/postgres/migrations/003_temperature_history.sql: %w", err)
	}

	checkCtx, checkCancel = context.WithTimeout(ctx, 5*time.Second)
	_, err = pool.Exec(checkCtx, "SELECT request_id, backend FROM weather_jobs LIMIT 0")
	checkCancel()
	if err != nil {
		return fmt.Errorf("apply infra/postgres/migrations/004_weather_jobs.sql and 005_postgres_queue.sql before starting History")
	}
	var preferencesStore domain.PreferenceStore
	var publisher domain.JobPublisher
	var workers sync.WaitGroup
	if cfg.Backend == config.BackendPostgres {
		checkCtx, checkCancel = context.WithTimeout(ctx, 5*time.Second)
		_, err = pool.Exec(checkCtx, "SELECT msg_id, message FROM pgmq.q_weather_requests LIMIT 0; SELECT msg_id, message FROM pgmq.q_weather_responses LIMIT 0")
		checkCancel()
		if err != nil {
			return fmt.Errorf("enable PGMQ and apply infra/postgres/migrations/005_postgres_queue.sql before starting History")
		}
		checkCtx, checkCancel = context.WithTimeout(ctx, 5*time.Second)
		_, err = pool.Exec(checkCtx, "SELECT session_id, preferences OPERATOR(public.->) 'theme', expires_at FROM weather_preferences LIMIT 0")
		checkCancel()
		if err != nil {
			return fmt.Errorf("apply infra/postgres/migrations/006_postgres_preferences.sql before starting History")
		}
		preferencesStore = store
		workers.Add(2)
		go func() { defer workers.Done(); store.RunConsumer(ctx) }()
		go func() { defer workers.Done(); store.RunPreferencesCleanup(ctx) }()
	} else {
		redisClient := rediscache.NewClient(cfg)
		defer redisClient.Close()
		preferencesStore = rediscache.New(redisClient)
		broker := rabbitmq.New(cfg.RabbitMQURL)
		publisher = broker
		workers.Add(2)
		go func() { defer workers.Done(); broker.RunPublisher(ctx) }()
		go func() { defer workers.Done(); broker.RunConsumer(ctx, store) }()
	}
	collector := app.NewCollector(store, store, publisher, cfg)
	preferences := api.NewPreferenceHandler(preferencesStore, cfg.SessionCookieSecure)
	workers.Add(1)
	go func() { defer workers.Done(); collector.RecoverJobs(ctx) }()
	defer workers.Wait()
	defer stop()
	server := &http.Server{
		Addr: cfg.Address, Handler: api.NewHandler(store, collector, cfg.UIDir, preferences),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 25 * time.Second, IdleTimeout: 60 * time.Second,
		BaseContext: func(net.Listener) context.Context { return ctx },
	}
	listener, err := net.Listen("tcp", cfg.Address)
	if err != nil {
		return err
	}
	schedulerDone := make(chan struct{})
	go func() { defer close(schedulerDone); app.RunScheduler(ctx, collector, cfg.Interval) }()
	temperatureDone := make(chan struct{})
	go func() {
		defer close(temperatureDone)
		app.RunTemperatureScheduler(ctx, collector, cfg.TemperatureInterval, cfg.TemperatureDays)
	}()
	serverErrors := make(chan error, 1)
	go func() { serverErrors <- server.Serve(listener) }()
	log.Printf("History http://%s; interval=%s; first automatic collection after interval", cfg.Address, cfg.Interval)
	log.Printf("Queue backend: %s", cfg.Backend)
	log.Printf("Temperature history: %d past days; sync on startup and every %s", cfg.TemperatureDays, cfg.TemperatureInterval)
	select {
	case <-ctx.Done():
	case err = <-serverErrors:
		if errors.Is(err, http.ErrServerClosed) {
			err = nil
		}
	}
	stop() // Cancel the timer, HTTP requests, and the current collection.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if shutdownErr := server.Shutdown(shutdownCtx); shutdownErr != nil {
		log.Printf("shutdown: %v", shutdownErr)
		_ = server.Close()
	}
	<-schedulerDone
	<-temperatureDone
	log.Print("History stopped")
	return err
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	if err := run(); err != nil {
		log.Printf("History startup/runtime error: %v", err)
		os.Exit(1)
	}
}
