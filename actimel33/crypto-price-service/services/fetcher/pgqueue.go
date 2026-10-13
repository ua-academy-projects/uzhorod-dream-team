package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// pgmq queues, created by db/migrations/003_pgmq.sql.
const (
	pgRequests = "price_requests"
	pgResults  = "price_results"
	pgBatch    = 10
	// read_with_poll waits this long on the server when the queue is empty.
	pgPollSeconds = 5
)

// pgQueue: BACKEND=postgres on the pgmq extension. A read message is leased for
// retryAfter; pgmq.delete is the ack, an expired lease brings the message back.
type pgQueue struct {
	pool *pgxpool.Pool
}

// newPgQueue does not connect yet: the role password or the queues may still be
// on their way from provisioning, and the read loop retries until they appear.
func newPgQueue(ctx context.Context, url string) (*pgQueue, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("parsing QUEUE_DATABASE_URL: %w", err)
	}
	log.Printf("[fetcher] backend: postgres, consuming pgmq %s", pgRequests)
	return &pgQueue{pool: pool}, nil
}

func (q *pgQueue) Close() { q.pool.Close() }

func (q *pgQueue) PublishResult(ctx context.Context, result PriceResult) error {
	payload, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("encoding result: %w", err)
	}
	_, err = q.pool.Exec(ctx, `SELECT pgmq.send($1, $2::jsonb)`, pgResults, string(payload))
	return err
}

type pgMessage struct {
	id      int64
	payload []byte
}

func (q *pgQueue) ReadRequests(ctx context.Context, handle RequestHandler) error {
	rows, err := q.pool.Query(ctx,
		`SELECT msg_id, message FROM pgmq.read_with_poll($1, $2, $3, $4)`,
		pgRequests, int(retryAfter.Seconds()), pgBatch, pgPollSeconds)
	if err != nil {
		return err
	}
	msgs, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (pgMessage, error) {
		var m pgMessage
		err := row.Scan(&m.id, &m.payload)
		return m, err
	})
	if err != nil {
		return err
	}
	for _, msg := range msgs {
		if ctx.Err() != nil {
			return nil // the lease brings the rest back
		}
		var req PriceRequest
		if err := json.Unmarshal(msg.payload, &req); err != nil {
			// Unparseable message: drop it, retrying cannot help.
			log.Printf("[worker] bad request %d: %v", msg.id, err)
			q.ack(ctx, msg.id)
			continue
		}
		if handle(ctx, req) {
			q.ack(ctx, msg.id)
		}
	}
	return nil
}

func (q *pgQueue) ack(ctx context.Context, id int64) {
	ctx, cancel := ackContext(ctx)
	defer cancel()
	if _, err := q.pool.Exec(ctx, `SELECT pgmq.delete($1, $2::bigint)`, pgRequests, id); err != nil {
		// Not fatal: the lease expires and the request is processed once more.
		log.Printf("[worker] ack %d failed: %v", id, err)
	}
}
