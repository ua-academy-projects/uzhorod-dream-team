package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

// startWorker consumes price requests until the context is cancelled.
// A message is acknowledged only after the result has been published, so a
// crash in the middle leaves the request for the next read instead of losing it.
func startWorker(ctx context.Context, rdb *redis.Client, source PriceSource) error {
	if err := ensureGroup(ctx, rdb, StreamRequests, GroupFetchers); err != nil {
		return err
	}
	log.Printf("[worker] consuming %s as %s", StreamRequests, consumerName)

	go func() {
		for {
			if ctx.Err() != nil {
				log.Print("[worker] stopped")
				return
			}
			if err := readOnce(ctx, rdb, source); err != nil && ctx.Err() == nil {
				log.Printf("[worker] read failed: %v", err)
				time.Sleep(time.Second)
			}
		}
	}()
	return nil
}

func readOnce(ctx context.Context, rdb *redis.Client, source PriceSource) error {
	if err := reclaimOnce(ctx, rdb, source); err != nil && !strings.Contains(err.Error(), "NOGROUP") {
		return err
	}
	streams, err := rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
		Group:    GroupFetchers,
		Consumer: consumerName,
		Streams:  []string{StreamRequests, ">"},
		Count:    10,
		Block:    readBlock,
	}).Result()
	if errors.Is(err, redis.Nil) {
		return nil // nothing arrived within the block window
	}
	// Redis keeps no data on disk here, so a restart wipes the stream and the
	// group with it. Recreate them instead of looping on the error forever.
	if err != nil && strings.Contains(err.Error(), "NOGROUP") {
		log.Print("[worker] consumer group vanished, recreating")
		return ensureGroup(ctx, rdb, StreamRequests, GroupFetchers)
	}
	if err != nil {
		return err
	}

	for _, stream := range streams {
		for _, message := range stream.Messages {
			handle(ctx, rdb, source, message)
		}
	}
	return nil
}

func handle(ctx context.Context, rdb *redis.Client, source PriceSource, msg redis.XMessage) {
	raw, _ := msg.Values["payload"].(string)

	var req PriceRequest
	if err := json.Unmarshal([]byte(raw), &req); err != nil {
		// Unparseable message: acknowledge it, retrying cannot help.
		log.Printf("[worker] bad request %s: %v", msg.ID, err)
		rdb.XAck(ctx, StreamRequests, GroupFetchers, msg.ID)
		return
	}

	points, origin, err := fetchFor(source, req)
	var unknown *ErrUnknownAsset
	if errors.As(err, &unknown) {
		log.Printf("[worker] %s, dropped", unknown)
		rdb.XAck(ctx, StreamRequests, GroupFetchers, msg.ID)
		return
	}
	if err != nil {
		// Unacked: reclaimOnce retries it after reclaimIdle.
		log.Printf("[worker] fetch %s/%s failed: %v", req.Coin, req.Vs, err)
		return
	}

	result := PriceResult{Coin: req.Coin, Vs: req.Vs, Origin: origin, Points: toItems(points)}
	if err := publishResult(ctx, rdb, result); err != nil {
		log.Printf("[worker] publish failed: %v", err)
		return
	}
	rdb.XAck(ctx, StreamRequests, GroupFetchers, msg.ID)
	log.Printf("[worker] %s/%s → %d point(s), origin %s", req.Coin, req.Vs, len(points), origin)
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
