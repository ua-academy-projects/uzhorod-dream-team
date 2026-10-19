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
)

func runScheduler(ctx context.Context, collector *Collector, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if ctx.Err() != nil {
				return
			}
			job, err := collector.Collect(ctx)
			if err != nil {
				log.Print("scheduled collection could not be queued")
				continue
			}
			log.Printf("scheduled collection queued request_id=%s", job.RequestID)
		}
	}
}

func run() error {
	config, err := loadConfig()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	dbConfig, err := pgxpool.ParseConfig(config.DatabaseURL)
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
	store := &Store{pool: pool, backend: config.Backend}
	if err := store.Ping(ctx); err != nil {
		return fmt.Errorf("connect PostgreSQL: %w", err)
	}
	checkCtx, checkCancel := context.WithTimeout(ctx, 5*time.Second)
	_, err = pool.Exec(checkCtx, "SELECT "+columns+" FROM weather_snapshots LIMIT 0")
	checkCancel()
	if err != nil {
		return fmt.Errorf("check weather_snapshots: apply migrations/001_create_weather_snapshots.sql: %w", err)
	}
	checkCtx, checkCancel = context.WithTimeout(ctx, 5*time.Second)
	_, err = pool.Exec(checkCtx, "SELECT city, weather_time, temperature_c FROM temperature_history LIMIT 0")
	checkCancel()
	if err != nil {
		return fmt.Errorf("check temperature_history: apply migrations/003_temperature_history.sql: %w", err)
	}

	checkCtx, checkCancel = context.WithTimeout(ctx, 5*time.Second)
	_, err = pool.Exec(checkCtx, "SELECT request_id, backend FROM weather_jobs LIMIT 0")
	checkCancel()
	if err != nil {
		return fmt.Errorf("apply migrations/004_weather_jobs.sql and 005_postgres_queue.sql before starting History")
	}
	redisClient := newRedisClient(config)
	defer redisClient.Close()
	preferences := &preferenceHandler{client: redisClient, secure: config.SessionCookieSecure}
	collector := &Collector{store: store, jobs: store, config: config}
	var workers sync.WaitGroup
	if config.Backend == backendPostgres {
		checkCtx, checkCancel = context.WithTimeout(ctx, 5*time.Second)
		_, err = pool.Exec(checkCtx, "SELECT msg_id, message FROM pgmq.q_weather_requests LIMIT 0; SELECT msg_id, message FROM pgmq.q_weather_responses LIMIT 0")
		checkCancel()
		if err != nil {
			return fmt.Errorf("enable PGMQ and apply migrations/005_postgres_queue.sql before starting History")
		}

		workers.Add(1)
		go func() { defer workers.Done(); store.runPostgresConsumer(ctx) }()
	} else {
		broker := newBroker(config.RabbitMQURL)
		collector.publisher = broker
		workers.Add(2)
		go func() { defer workers.Done(); broker.runPublisher(ctx) }()
		go func() { defer workers.Done(); broker.runConsumer(ctx, store) }()
	}
	workers.Add(1)
	go func() { defer workers.Done(); collector.recoverJobs(ctx) }()
	defer workers.Wait()
	defer stop()
	server := &http.Server{
		Addr: config.Address, Handler: newHandler(store, collector, config.UIDir, preferences),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 25 * time.Second, IdleTimeout: 60 * time.Second,
		BaseContext: func(net.Listener) context.Context { return ctx },
	}
	listener, err := net.Listen("tcp", config.Address)
	if err != nil {
		return err
	}
	schedulerDone := make(chan struct{})
	go func() { defer close(schedulerDone); runScheduler(ctx, collector, config.Interval) }()
	temperatureDone := make(chan struct{})
	go func() {
		defer close(temperatureDone)
		runTemperatureScheduler(ctx, collector, config.TemperatureInterval, config.TemperatureDays)
	}()
	serverErrors := make(chan error, 1)
	go func() { serverErrors <- server.Serve(listener) }()
	log.Printf("History http://%s; interval=%s; first automatic collection after interval", config.Address, config.Interval)
	log.Printf("Queue backend: %s", config.Backend)
	log.Printf("Temperature history: %d past days; sync on startup and every %s", config.TemperatureDays, config.TemperatureInterval)
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
