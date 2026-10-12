package main

import (
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	pgBatch = 10
	// Fallback for a missed notification.
	pgPoll = 5 * time.Second
)

// pgQueue: queue_messages table; SKIP LOCKED + lease instead of a consumer group,
// DELETE as the ack, LISTEN/NOTIFY to wake up. Schema: db/migrations/002_queue.sql.
type pgQueue struct {
	url  string
	pool *pgxpool.Pool
}

// newPgQueue does not connect yet: the role password or the table may still be
// on their way from provisioning, and the loops below retry until they appear.
func newPgQueue(ctx context.Context, url string) (*pgQueue, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("parsing QUEUE_DATABASE_URL: %w", err)
	}
	return &pgQueue{url: url, pool: pool}, nil
}

func (q *pgQueue) Close() { q.pool.Close() }

func (q *pgQueue) PublishResult(ctx context.Context, result PriceResult) error {
	payload, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("encoding result: %w", err)
	}
	_, err = q.pool.Exec(ctx,
		`INSERT INTO queue_messages (topic, payload) VALUES ($1, $2)`, TopicResults, payload)
	return err
}

func (q *pgQueue) ConsumeRequests(ctx context.Context, handle RequestHandler) error {
	log.Printf("[worker] consuming %s from postgres as %s", TopicRequests, consumerName)
	wake := make(chan struct{}, 1)
	go q.listen(ctx, wake)

	go func() {
		for ctx.Err() == nil {
			n, err := q.readOnce(ctx, handle)
			if err != nil && ctx.Err() == nil {
				log.Printf("[worker] read failed: %v", err)
				time.Sleep(time.Second)
				continue
			}
			if n == pgBatch {
				continue // more may be waiting
			}
			select {
			case <-ctx.Done():
			case <-wake:
			case <-time.After(pgPoll):
			}
		}
		log.Print("[worker] stopped")
	}()
	return nil
}

type pgMessage struct {
	id      int64
	payload []byte
}

func (q *pgQueue) readOnce(ctx context.Context, handle RequestHandler) (int, error) {
	msgs, err := q.take(ctx)
	if err != nil {
		return 0, err
	}
	for _, msg := range msgs {
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
	return len(msgs), nil
}

// take leases up to pgBatch ready requests; other consumers skip the locked rows.
func (q *pgQueue) take(ctx context.Context) ([]pgMessage, error) {
	rows, err := q.pool.Query(ctx, `
		UPDATE queue_messages
		   SET available_at = now() + make_interval(secs => $2), attempts = attempts + 1
		 WHERE id IN (SELECT id FROM queue_messages
		               WHERE topic = $1 AND available_at <= now()
		               ORDER BY id LIMIT $3
		               FOR UPDATE SKIP LOCKED)
		RETURNING id, payload`,
		TopicRequests, retryAfter.Seconds(), pgBatch)
	if err != nil {
		return nil, err
	}
	msgs, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (pgMessage, error) {
		var m pgMessage
		err := row.Scan(&m.id, &m.payload)
		return m, err
	})
	if err != nil {
		return nil, err
	}
	// RETURNING does not keep the subquery order.
	slices.SortFunc(msgs, func(a, b pgMessage) int { return cmp.Compare(a.id, b.id) })
	return msgs, nil
}

func (q *pgQueue) ack(ctx context.Context, id int64) {
	if _, err := q.pool.Exec(ctx, `DELETE FROM queue_messages WHERE id = $1`, id); err != nil {
		// Not fatal: the lease expires and the request is processed once more.
		log.Printf("[worker] ack %d failed: %v", id, err)
	}
}

// listen keeps a dedicated connection on LISTEN and nudges the reader on every insert.
func (q *pgQueue) listen(ctx context.Context, wake chan<- struct{}) {
	for ctx.Err() == nil {
		if err := q.listenOnce(ctx, wake); err != nil && ctx.Err() == nil {
			log.Printf("[worker] listen: %v", err)
			time.Sleep(time.Second)
		}
	}
}

func (q *pgQueue) listenOnce(ctx context.Context, wake chan<- struct{}) error {
	conn, err := pgx.Connect(ctx, q.url)
	if err != nil {
		return err
	}
	defer conn.Close(context.Background())
	if _, err := conn.Exec(ctx, fmt.Sprintf("LISTEN %q", TopicRequests)); err != nil {
		return err
	}
	for {
		if _, err := conn.WaitForNotification(ctx); err != nil {
			return err
		}
		select {
		case wake <- struct{}{}:
		default: // a wake-up is already pending
		}
	}
}
