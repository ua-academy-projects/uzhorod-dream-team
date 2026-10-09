package main

import (
	"context"
	"time"

	"github.com/redis/go-redis/v9"
)

// Unacked messages older than this are taken over and retried.
const reclaimIdle = 30 * time.Second

// reclaimOnce retries requests left unacknowledged by a failed attempt.
// Reading with ">" returns only new messages, so without this they stay pending forever.
func reclaimOnce(ctx context.Context, rdb *redis.Client, source PriceSource) error {
	msgs, _, err := rdb.XAutoClaim(ctx, &redis.XAutoClaimArgs{
		Stream:   StreamRequests,
		Group:    GroupFetchers,
		Consumer: consumerName,
		MinIdle:  reclaimIdle,
		Start:    "0",
		Count:    10,
	}).Result()
	if err != nil {
		return err
	}
	for _, msg := range msgs {
		handle(ctx, rdb, source, msg)
	}
	return nil
}
