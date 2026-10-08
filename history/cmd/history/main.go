package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"
	"github.com/redis/go-redis/v9"

	"history/internal/config"
	"history/internal/db"
	"history/internal/httpmiddleware"
	"history/internal/locations"
	"history/internal/measurements"
	"history/internal/parameters"
	"history/internal/sessions"
	"history/internal/syncer"
)

func main() {
	cfg := config.Load()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	log.Println("Connecting to database...")
	pool, err := db.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("Database connection failed: %v", err)
	}
	defer pool.Close()
	log.Println("Database connection established.")

	locRepo := locations.NewRepository(pool)
	paramRepo := parameters.NewRepository(pool)
	measRepo := measurements.NewRepository(pool)

	fetcherClient := syncer.NewFetcherClient(ctx, cfg.RabbitMQ, cfg.FetcherTimeout)
	defer fetcherClient.Close()

	svc := locations.NewService(locRepo, paramRepo, measRepo)
	handler := locations.NewHandler(svc)

	redisOptions, err := redis.ParseURL(cfg.RedisURL)
	if err != nil {
		log.Fatal("Invalid REDIS_URL configuration")
	}
	redisOptions.DialTimeout = cfg.SessionRedisTimeout
	redisOptions.ReadTimeout = cfg.SessionRedisTimeout
	redisOptions.WriteTimeout = cfg.SessionRedisTimeout
	redisOptions.ContextTimeoutEnabled = true
	redisOptions.MaxRetries = -1

	redisClient := redis.NewClient(redisOptions)
	defer redisClient.Close()

	sessionService := sessions.NewService(sessions.NewRepository(redisClient), cfg.SessionTTL, nil)
	sessionHandler := sessions.NewHandler(sessionService, sessions.HandlerOptions{
		TTL: cfg.SessionTTL, Timeout: cfg.SessionRedisTimeout,
		Secure: cfg.SessionCookieSecure,
	})

	syncWorker := syncer.NewSyncer(cfg, locRepo, paramRepo, measRepo, fetcherClient)

	syncDone := make(chan struct{})
	go func() {
		defer close(syncDone)
		syncWorker.Start(ctx)
	}()

	r := chi.NewRouter()
	r.Use(middleware.Heartbeat("/health"))

	r.Use(cors.Handler(cors.Options{
		AllowedOrigins:   cfg.AllowedOrigins,
		AllowedMethods:   []string{"GET", "POST", "PUT", "DELETE", "OPTIONS"},
		AllowedHeaders:   []string{"Accept", "Authorization", "Content-Type", "X-CSRF-Token"},
		ExposedHeaders:   []string{"Link"},
		AllowCredentials: true,
		MaxAge:           300,
	}))

	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
		sessionHandler.RegisterRoutes(r, httpmiddleware.RequireAllowedOrigin(cfg.AllowedOrigins))
	})

	server := &http.Server{
		Addr:    ":" + cfg.Port,
		Handler: r,
	}

	shutdownDone := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		<-ctx.Done()

		log.Println("Shutting down gracefully...")
		cancel()

		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutdownCancel()

		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Printf("HTTP server shutdown error: %v", err)
		}
	}()

	log.Printf("Starting History Service on port %s", cfg.Port)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("Could not listen on %s: %v\n", cfg.Port, err)
	}
	cancel()
	<-syncDone
	<-shutdownDone
}
