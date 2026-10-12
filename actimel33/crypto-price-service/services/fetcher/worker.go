package main

import (
	"context"
	"errors"
	"log"
)

// startWorker consumes price requests until the context is cancelled. A request
// is acknowledged only after its result has been published, so a crash in the
// middle leaves it for a retry instead of losing it.
func startWorker(ctx context.Context, q Queue, source PriceSource) error {
	return q.ConsumeRequests(ctx, func(ctx context.Context, req PriceRequest) bool {
		return process(ctx, q, source, req)
	})
}

func process(ctx context.Context, q Queue, source PriceSource, req PriceRequest) bool {
	points, origin, err := fetchFor(source, req)
	var unknown *ErrUnknownAsset
	if errors.As(err, &unknown) {
		log.Printf("[worker] %s, dropped", unknown)
		return true
	}
	if err != nil {
		log.Printf("[worker] fetch %s/%s failed: %v", req.Coin, req.Vs, err)
		return false
	}

	result := PriceResult{Coin: req.Coin, Vs: req.Vs, Origin: origin, Points: toItems(points)}
	if err := q.PublishResult(ctx, result); err != nil {
		log.Printf("[worker] publish failed: %v", err)
		return false
	}
	log.Printf("[worker] %s/%s → %d point(s), origin %s", req.Coin, req.Vs, len(points), origin)
	return true
}

func fetchFor(source PriceSource, req PriceRequest) ([]PricePoint, string, error) {
	if req.Days > 0 {
		points, err := source.Chart(req.Coin, req.Vs, req.Days)
		return points, "bootstrap", err
	}
	point, err := source.Quote(req.Coin, req.Vs)
	if err != nil {
		return nil, "", err
	}
	return []PricePoint{point}, "on_demand", nil
}
