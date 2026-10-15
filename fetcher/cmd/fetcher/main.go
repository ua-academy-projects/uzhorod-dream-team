package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"fetcher/internal/config"
	"fetcher/internal/locations"
	"fetcher/internal/openaq"
	"fetcher/internal/postgresqueue"
	"fetcher/internal/rabbitmq"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}
	aqClient := openaq.NewClient(cfg)
	locService := locations.NewService(aqClient)
	locHandler := locations.NewHandler(locService)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	var worker interface{ Run(context.Context) }
	if cfg.PostgresOnly {
		pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
		if err != nil {
			log.Fatalf("Invalid PostgreSQL configuration: %v", err)
		}
		defer pool.Close()
		worker = postgresqueue.NewWorker(pool, locations.NewMessageHandler(locService))
	} else {
		worker = rabbitmq.NewWorker(cfg.RabbitMQ, locations.NewMessageHandler(locService))
	}
	workerDone := make(chan struct{})
	go func() {
		defer close(workerDone)
		worker.Run(ctx)
	}()

	r := chi.NewRouter()
	r.Use(middleware.Heartbeat("/health"))
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	r.Route("/api/v1", func(r chi.Router) {
		locHandler.RegisterRoutes(r)
	})

	server := &http.Server{Addr: ":" + cfg.Port, Handler: r}
	shutdownDone := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		<-ctx.Done()
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutdownCancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Printf("HTTP server shutdown error: %v", err)
		}
	}()
	log.Printf("Starting Fetcher Service on port %s", cfg.Port)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("Server failed to start: %v", err)
	}
	cancel()
	<-workerDone
	<-shutdownDone
}
