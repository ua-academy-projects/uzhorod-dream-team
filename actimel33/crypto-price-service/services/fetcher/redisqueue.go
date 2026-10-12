package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	groupFetchers = "fetchers"
	maxStreamLen  = 1000
	readBlock     = 5 * time.Second
)

// redisQueue: Redis Streams with a consumer group; ack after success, XAUTOCLAIM for retries.
type redisQueue struct {
	rdb *redis.Client
}

func newRedisQueue(ctx context.Context, url, password string) (*redisQueue, error) {
	opts, err := redis.ParseURL(url)
	if err != nil {
		return nil, fmt.Errorf("parsing REDIS_URL: %w", err)
	}
	if password != "" {
		opts.Password = password
	}
	rdb := redis.NewClient(opts)
	if err := rdb.Ping(ctx).Err(); err != nil {
		rdb.Close()
		return nil, fmt.Errorf("connecting to redis at %s: %w", url, err)
	}
	return &redisQueue{rdb: rdb}, nil
}

func (q *redisQueue) Close() { q.rdb.Close() }

func (q *redisQueue) PublishResult(ctx context.Context, result PriceResult) error {
	payload, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("encoding result: %w", err)
	}
	return q.rdb.XAdd(ctx, &redis.XAddArgs{
		Stream: TopicResults,
		MaxLen: maxStreamLen,
		Approx: true,
		Values: map[string]any{"payload": string(payload)},
	}).Err()
}

func (q *redisQueue) ConsumeRequests(ctx context.Context, handle RequestHandler) error {
	if err := q.ensureGroup(ctx); err != nil {
		return err
	}
	log.Printf("[worker] consuming %s from redis as %s", TopicRequests, consumerName)

	go func() {
		for ctx.Err() == nil {
			if err := q.readOnce(ctx, handle); err != nil && ctx.Err() == nil {
				log.Printf("[worker] read failed: %v", err)
				time.Sleep(time.Second)
			}
		}
		log.Print("[worker] stopped")
	}()
	return nil
}

// ensureGroup creates the consumer group, tolerating the one that already exists.
func (q *redisQueue) ensureGroup(ctx context.Context) error {
	err := q.rdb.XGroupCreateMkStream(ctx, TopicRequests, groupFetchers, "0").Err()
	if err != nil && err.Error() != "BUSYGROUP Consumer Group name already exists" {
		return fmt.Errorf("creating group %s on %s: %w", groupFetchers, TopicRequests, err)
	}
	return nil
}

func (q *redisQueue) readOnce(ctx context.Context, handle RequestHandler) error {
	if err := q.reclaimOnce(ctx, handle); err != nil && !strings.Contains(err.Error(), "NOGROUP") {
		return err
	}
	streams, err := q.rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
		Group:    groupFetchers,
		Consumer: consumerName,
		Streams:  []string{TopicRequests, ">"},
		Count:    10,
		Block:    readBlock,
	}).Result()
	if errors.Is(err, redis.Nil) {
		return nil // nothing arrived within the block window
	}
	// A Redis restart without its data wipes the stream and the group with it.
	if err != nil && strings.Contains(err.Error(), "NOGROUP") {
		log.Print("[worker] consumer group vanished, recreating")
		return q.ensureGroup(ctx)
	}
	if err != nil {
		return err
	}
	for _, stream := range streams {
		for _, msg := range stream.Messages {
			q.deliver(ctx, msg, handle)
		}
	}
	return nil
}

// reclaimOnce retries requests left unacknowledged by a failed attempt:
// reading with ">" returns only new messages, so without this they stay pending forever.
func (q *redisQueue) reclaimOnce(ctx context.Context, handle RequestHandler) error {
	msgs, _, err := q.rdb.XAutoClaim(ctx, &redis.XAutoClaimArgs{
		Stream:   TopicRequests,
		Group:    groupFetchers,
		Consumer: consumerName,
		MinIdle:  retryAfter,
		Start:    "0",
		Count:    10,
	}).Result()
	if err != nil {
		return err
	}
	for _, msg := range msgs {
		q.deliver(ctx, msg, handle)
	}
	return nil
}

func (q *redisQueue) deliver(ctx context.Context, msg redis.XMessage, handle RequestHandler) {
	raw, _ := msg.Values["payload"].(string)
	var req PriceRequest
	if err := json.Unmarshal([]byte(raw), &req); err != nil {
		// Unparseable message: acknowledge it, retrying cannot help.
		log.Printf("[worker] bad request %s: %v", msg.ID, err)
		q.rdb.XAck(ctx, TopicRequests, groupFetchers, msg.ID)
		return
	}
	if handle(ctx, req) {
		q.rdb.XAck(ctx, TopicRequests, groupFetchers, msg.ID)
	}
}
