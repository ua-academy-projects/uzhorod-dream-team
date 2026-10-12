package main

import (
	"context"
	"os"
	"time"
)

// Topics carrying the conversation between history and fetcher, the same for
// both drivers: Redis stream names or the topic column of queue_messages.
const (
	TopicRequests = "price:requests"
	TopicResults  = "price:results"
	// Unacknowledged messages older than this are taken over and retried.
	retryAfter = 30 * time.Second
)

// Queue hides the transport; worker and timer talk only to it.
type Queue interface {
	// ConsumeRequests runs handle for every request in the background until ctx ends.
	ConsumeRequests(ctx context.Context, handle RequestHandler) error
	PublishResult(ctx context.Context, result PriceResult) error
	Close()
}

// RequestHandler reports whether the message is done (processed, or retrying
// cannot help) and may be acknowledged; false leaves it for a retry.
type RequestHandler func(ctx context.Context, req PriceRequest) (ack bool)

// Unique per instance, so several fetchers can share the work.
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
