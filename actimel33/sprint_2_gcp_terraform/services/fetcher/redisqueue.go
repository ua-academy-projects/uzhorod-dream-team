package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

// Streams carrying the conversation with history: requests one way, results the other.
const (
	streamRequests = "price:requests"
	streamResults  = "price:results"
	groupFetchers  = "fetchers"
	maxStreamLen   = 1000
	readBlock      = 5 * time.Second
)

// The container hostname: one consumer name per fetcher instance.
var consumerName = func() string {
	if h, err := os.Hostname(); err == nil {
		return h
	}
	return "fetcher"
}()

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
	q := &redisQueue{rdb: redis.NewClient(opts)}
	if err := q.rdb.Ping(ctx).Err(); err != nil {
		q.Close()
		return nil, fmt.Errorf("connecting to redis at %s: %w", opts.Addr, err)
	}
	if err := q.ensureGroup(ctx); err != nil {
		q.Close()
		return nil, err
	}
	log.Printf("[fetcher] backend: redis %s, consuming %s as %s", opts.Addr, streamRequests, consumerName)
	return q, nil
}

func (q *redisQueue) Close() { q.rdb.Close() }

func (q *redisQueue) PublishResult(ctx context.Context, result PriceResult) error {
	payload, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("encoding result: %w", err)
	}
	return q.rdb.XAdd(ctx, &redis.XAddArgs{
		Stream: streamResults,
		MaxLen: maxStreamLen,
		Approx: true,
		Values: map[string]any{"payload": string(payload)},
	}).Err()
}

// ensureGroup creates the consumer group, tolerating the one that already exists.
func (q *redisQueue) ensureGroup(ctx context.Context) error {
	err := q.rdb.XGroupCreateMkStream(ctx, streamRequests, groupFetchers, "0").Err()
	if err != nil && !strings.HasPrefix(err.Error(), "BUSYGROUP") {
		return fmt.Errorf("creating group %s on %s: %w", groupFetchers, streamRequests, err)
	}
	return nil
}

func (q *redisQueue) ReadRequests(ctx context.Context, handle RequestHandler) error {
	// ">" returns only new messages: without the reclaim a failed request would stay pending forever.
	claimed, _, err := q.rdb.XAutoClaim(ctx, &redis.XAutoClaimArgs{
		Stream:   streamRequests,
		Group:    groupFetchers,
		Consumer: consumerName,
		MinIdle:  retryAfter,
		Start:    "0",
		Count:    10,
	}).Result()
	if err != nil && ctx.Err() == nil {
		log.Printf("[worker] reclaim failed: %v", err)
	}
	q.deliver(ctx, claimed, handle)

	streams, err := q.rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
		Group:    groupFetchers,
		Consumer: consumerName,
		Streams:  []string{streamRequests, ">"},
		Count:    10,
		Block:    readBlock,
	}).Result()
	if errors.Is(err, redis.Nil) {
		return nil // nothing arrived within the block window
	}
	// Losing Redis data (no AOF, a new volume) takes the stream and the group with it.
	if err != nil && strings.Contains(err.Error(), "NOGROUP") {
		log.Print("[worker] consumer group vanished, recreating")
		return q.ensureGroup(ctx)
	}
	if err != nil {
		return err
	}
	for _, stream := range streams {
		q.deliver(ctx, stream.Messages, handle)
	}
	return nil
}

func (q *redisQueue) deliver(ctx context.Context, msgs []redis.XMessage, handle RequestHandler) {
	for _, msg := range msgs {
		if ctx.Err() != nil {
			return // the rest is reclaimed by the next instance
		}
		raw, _ := msg.Values["payload"].(string)
		var req PriceRequest
		if err := json.Unmarshal([]byte(raw), &req); err != nil {
			// Unparseable message: acknowledge it, retrying cannot help.
			log.Printf("[worker] bad request %s: %v", msg.ID, err)
			q.ack(ctx, msg.ID)
			continue
		}
		if handle(ctx, req) {
			q.ack(ctx, msg.ID)
		}
	}
}

func (q *redisQueue) ack(ctx context.Context, id string) {
	ctx, cancel := ackContext(ctx)
	defer cancel()
	if err := q.rdb.XAck(ctx, streamRequests, groupFetchers, id).Err(); err != nil {
		// Not fatal: the message is reclaimed and processed once more.
		log.Printf("[worker] ack %s failed: %v", id, err)
	}
}
