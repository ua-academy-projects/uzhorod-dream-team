package main

import (
	"context"
	"log"
	"time"

	"github.com/redis/go-redis/v9"
)

const minInterval = time.Second

// startTimer samples the price on a schedule. The first tick fires after the
// interval rather than at startup: History has already filled the database with
// its bootstrap by then, and an extra call would only burn the CoinGecko quota.
func startTimer(ctx context.Context, cfg *Config, source PriceSource, rdb *redis.Client) {
	interval := time.Duration(cfg.TimerIntervalHrs * float64(time.Hour))
	if interval < minInterval {
		interval = minInterval
	}

	ticker := time.NewTicker(interval)
	log.Printf("[timer] started: every %gh (%s)", cfg.TimerIntervalHrs, interval)

	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				log.Print("[timer] stopped")
				return
			case <-ticker.C:
				tick(ctx, cfg, source, rdb)
			}
		}
	}()
}

func tick(ctx context.Context, cfg *Config, source PriceSource, rdb *redis.Client) {
	point, err := source.Quote(cfg.DefaultCoin, cfg.DefaultVs)
	if err != nil {
		log.Printf("[timer] tick failed: %v", err)
		return
	}
	result := PriceResult{
		Coin:   cfg.DefaultCoin,
		Vs:     cfg.DefaultVs,
		Origin: "timer",
		Points: toItems([]PricePoint{point}),
	}
	if err := publishResult(ctx, rdb, result); err != nil {
		log.Printf("[timer] publish failed: %v", err)
		return
	}
	log.Printf("[timer] tick ok: price=%g published", point.Price)
}
