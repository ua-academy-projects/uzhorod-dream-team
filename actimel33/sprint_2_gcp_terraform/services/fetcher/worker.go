package main

import (
	"context"
	"errors"
	"log"
	"time"
)

// startWorker consumes price requests until the context is cancelled. A request
// is acknowledged only after its result has been published, so a crash in the
// middle leaves it for a retry instead of losing it.
func startWorker(ctx context.Context, q Queue, source PriceSource) {
	handle := func(ctx context.Context, req PriceRequest) bool { return process(ctx, q, source, req) }
	go func() {
		for ctx.Err() == nil {
			if err := q.ReadRequests(ctx, handle); err != nil && ctx.Err() == nil {
				log.Printf("[worker] read failed: %v", err)
				select {
				case <-ctx.Done():
				case <-time.After(time.Second):
				}
			}
		}
		log.Print("[worker] stopped")
	}()
}

func process(ctx context.Context, q Queue, source PriceSource, req PriceRequest) bool {
	points, origin, err := fetchFor(source, req)
	var unknown *ErrUnknownAsset
	var fatal *fatalUpstream
	if errors.As(err, &unknown) || errors.As(err, &fatal) {
		// A retry cannot change the answer: drop it rather than ask again every 30 s.
		log.Printf("[worker] %s/%s: %v, dropped", req.Coin, req.Vs, err)
		return true
	}
	if err != nil {
		log.Printf("[worker] fetch %s/%s failed: %v", req.Coin, req.Vs, err)
		return false
	}
	if err := publish(ctx, q, req.Coin, req.Vs, origin, points); err != nil {
		log.Printf("[worker] publish failed: %v", err)
		return false
	}
	log.Printf("[worker] %s/%s → %d point(s), origin %s", req.Coin, req.Vs, len(points), origin)
	return true
}

func publish(ctx context.Context, q Queue, coin, vs, origin string, points []PricePoint) error {
	return q.PublishResult(ctx, PriceResult{Coin: coin, Vs: vs, Origin: origin, Points: toItems(points)})
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
