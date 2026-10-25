package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck())
	}

	if err := run(); err != nil {
		log.Fatalf("[fetcher] %v", err)
	}
}

func run() error {
	cfg, err := LoadConfig()
	if err != nil {
		return err
	}

	client := newRetryClient(time.Duration(cfg.HTTPTimeoutMillis)*time.Millisecond, cfg.RetryAttempts)
	source := newCoinGecko(cfg.CoinGeckoBaseURL, client)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	q, err := openQueue(ctx, cfg)
	if err != nil {
		return err
	}
	defer q.Close()

	startWorker(ctx, q, source)
	startTimer(ctx, cfg, source, q)

	srv := &server{backend: cfg.Backend}
	addr := fmt.Sprintf("%s:%d", cfg.Host, cfg.Port)
	httpServer := &http.Server{
		Addr:              addr,
		Handler:           srv.routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			log.Printf("[fetcher] shutdown: %v", err)
		}
	}()

	// HTTP serves the health check only; the service
	// itself no longer talks to history over HTTP, only through the queue.
	log.Printf("[fetcher] listening on http://%s", addr)
	log.Printf("[fetcher] upstream: %s", cfg.CoinGeckoBaseURL)

	if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return err
	}
	log.Print("[fetcher] stopped")
	_ = os.Stdout.Sync()
	return nil
}

// openQueue picks the driver by BACKEND; the rest of the service does not know which.
func openQueue(ctx context.Context, cfg *Config) (Queue, error) {
	if cfg.Backend == "postgres" {
		return newPgQueue(ctx, cfg.QueueDatabaseURL)
	}
	return newRedisQueue(ctx, cfg.RedisURL, cfg.RedisPassword)
}

// healthcheck is the Docker HEALTHCHECK: distroless has no curl.
func healthcheck() int {
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + envStr("FETCHER_PORT", "3002") + "/health")
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
