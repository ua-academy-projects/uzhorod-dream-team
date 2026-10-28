package main

import (
	"context"
	"time"
)

// Unacknowledged messages older than this are taken over and retried.
const retryAfter = 30 * time.Second

// Queue hides the transport; worker and timer talk only to it.
type Queue interface {
	// ReadRequests waits a few seconds for requests and runs handle on each one.
	ReadRequests(ctx context.Context, handle RequestHandler) error
	PublishResult(ctx context.Context, result PriceResult) error
	Close()
}

// RequestHandler reports whether the message is done (processed, or retrying
// cannot help) and may be acknowledged; false leaves it for a retry.
type RequestHandler func(ctx context.Context, req PriceRequest) (ack bool)

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

// ackContext lets an ack finish during shutdown: the work is already done.
func ackContext(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
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
