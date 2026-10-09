package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/redis/go-redis/v9"
)

// Streams carrying the conversation between history and fetcher.
// Requests travel one way, results the other; neither service knows the other's
// address any more — both only know Redis.
const (
	StreamRequests = "price:requests"
	StreamResults  = "price:results"
	GroupFetchers  = "fetchers"
	maxStreamLen   = 1000
	readBlock      = 5 * time.Second
)

// Unique per instance, so several fetchers can share the group.
var consumerName = func() string {
	if h, err := os.Hostname(); err == nil {
		return h
	}
	return "fetcher"
}()

// PriceRequest asks for a current quote, or for `days` of history when Days > 0.
type PriceRequest struct {
	Coin string `json:"coin"`
	Vs   string `json:"vs"`
	Days int    `json:"days,omitempty"`
}

// PriceResult carries what was fetched, plus the origin to store it under.
type PriceResult struct {
	Coin   string       `json:"coin"`
	Vs     string       `json:"vs"`
	Origin string       `json:"origin"`
	Points []resultItem `json:"points"`
}

type resultItem struct {
	Price      float64 `json:"price"`
	ObservedAt string  `json:"observedAt"`
}

func newRedis(url, password string) (*redis.Client, error) {
	opts, err := redis.ParseURL(url)
	if err != nil {
		return nil, fmt.Errorf("parsing REDIS_URL: %w", err)
	}
	if password != "" {
		opts.Password = password
	}
	return redis.NewClient(opts), nil
}

// ensureGroup creates the consumer group, tolerating the one that already exists.
func ensureGroup(ctx context.Context, rdb *redis.Client, stream, group string) error {
	err := rdb.XGroupCreateMkStream(ctx, stream, group, "0").Err()
	if err != nil && err.Error() != "BUSYGROUP Consumer Group name already exists" {
		return fmt.Errorf("creating group %s on %s: %w", group, stream, err)
	}
	return nil
}

func publishResult(ctx context.Context, rdb *redis.Client, result PriceResult) error {
	payload, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("encoding result: %w", err)
	}
	return rdb.XAdd(ctx, &redis.XAddArgs{
		Stream: StreamResults,
		MaxLen: maxStreamLen,
		Approx: true,
		Values: map[string]any{"payload": string(payload)},
	}).Err()
}

func toItems(points []PricePoint) []resultItem {
	items := make([]resultItem, 0, len(points))
	for _, p := range points {
		items = append(items, resultItem{
			Price:      p.Price,
			ObservedAt: p.ObservedAt.Format(time.RFC3339),
		})
	}
	return items
}
