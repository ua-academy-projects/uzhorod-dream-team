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
		resp, err := http.Get("http://127.0.0.1:" + envStr("FETCHER_PORT", "3002") + "/health")
		if err != nil || resp.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		os.Exit(0)
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

	rdb, err := newRedis(cfg.RedisURL, cfg.RedisPassword)
	if err != nil {
		return err
	}
	defer rdb.Close()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := rdb.Ping(ctx).Err(); err != nil {
		return fmt.Errorf("connecting to redis at %s: %w", cfg.RedisURL, err)
	}
	log.Printf("[fetcher] redis: %s", cfg.RedisURL)

	if err := startWorker(ctx, rdb, source); err != nil {
		return err
	}
	startTimer(ctx, cfg, source, rdb)

	srv := &server{source: source}
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
