package worker

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// PGMQRequestQueue is the pgmq queue shared with the History service (the reply queue comes in ReplyTo).
const PGMQRequestQueue = "weather_fetch_requests"

const (
	visibilityTimeout = 30              // seconds a read request stays hidden; then it is delivered again
	pollSeconds       = 5               // read_with_poll waits this long for a request
	pollIntervalMs    = 250             // and checks this often
	dbTimeout         = 5 * time.Second // sending the reply and deleting the request
)

type pgmqMessage struct {
	id      int64
	body    []byte
	headers Headers
}

// RunPGMQ consumes requests from pgmq until ctx is cancelled (returns nil) or a database call
// fails (returns an error). Like RunAMQP it does not reconnect: the process exits and Docker restarts it.
func RunPGMQ(ctx context.Context, url string, w Weather) error {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return fmt.Errorf("parse DATABASE_URL: %w", err)
	}
	cfg.MaxConns = prefetch + 1 // one reads, the others reply
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return fmt.Errorf("connect to PostgreSQL: %w", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		return fmt.Errorf("connect to PostgreSQL: %w", err)
	}
	slog.Info("Fetcher worker consuming", "broker", "pgmq", "queue", PGMQRequestQueue)

	// In-flight requests finish (and get deleted) before the pool is closed
	var wg sync.WaitGroup
	defer wg.Wait()
	// A token per request in progress: at most `prefetch` at a time, like the AMQP prefetch
	slots := make(chan struct{}, prefetch)

	for {
		select {
		case <-ctx.Done():
			slog.Info("shutting down")
			return nil
		case slots <- struct{}{}:
		}
		// Only this loop takes slots, so the free ones stay free until we take them below
		msgs, err := read(ctx, pool, cap(slots)-len(slots)+1)
		if err != nil {
			<-slots
			if ctx.Err() != nil {
				slog.Info("shutting down")
				return nil
			}
			return fmt.Errorf("read %s: %w", PGMQRequestQueue, err)
		}
		if len(msgs) == 0 {
			<-slots
			continue
		}
		for range msgs[1:] {
			slots <- struct{}{}
		}
		for _, m := range msgs {
			wg.Add(1)
			go func() {
				defer wg.Done()
				defer func() { <-slots }()
				respondPGMQ(pool, w, m)
			}()
		}
	}
}

func read(ctx context.Context, pool *pgxpool.Pool, qty int) ([]pgmqMessage, error) {
	rows, err := pool.Query(ctx, "SELECT msg_id, message, headers FROM pgmq.read_with_poll($1, $2, $3, $4, $5)",
		PGMQRequestQueue, visibilityTimeout, qty, pollSeconds, pollIntervalMs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var msgs []pgmqMessage
	for rows.Next() {
		var m pgmqMessage
		var headers []byte
		if err := rows.Scan(&m.id, &m.body, &headers); err != nil {
			return nil, err
		}
		m.headers = parseHeaders(headers)
		msgs = append(msgs, m)
	}
	return msgs, rows.Err()
}

// respondPGMQ handles one request. The reply is sent and the request deleted in one transaction:
// if either fails, the request becomes visible again after the visibility timeout and is retried.
func respondPGMQ(pool *pgxpool.Pool, w Weather, m pgmqMessage) {
	h := m.headers
	switch {
	case h.ReplyTo == "":
		slog.Warn("dropping request without replyTo", "msgId", m.id, "correlationId", h.CorrelationID)
		deleteRequest(pool, m)
		return
	case h.Expired(time.Now()):
		slog.Warn("dropping expired request", "msgId", m.id, "correlationId", h.CorrelationID)
		deleteRequest(pool, m)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), fetchTimeout)
	reply := encodeReply(Handle(ctx, w, m.body))
	cancel()

	replyHeaders, _ := json.Marshal(Headers{CorrelationID: h.CorrelationID})
	ctx, cancel = context.WithTimeout(context.Background(), dbTimeout)
	defer cancel()
	tx, err := pool.Begin(ctx)
	if err == nil {
		defer tx.Rollback(ctx) // no-op after Commit
		_, err = tx.Exec(ctx, "SELECT pgmq.send($1, $2::jsonb, $3::jsonb)",
			h.ReplyTo, json.RawMessage(reply), json.RawMessage(replyHeaders))
	}
	if err == nil {
		_, err = tx.Exec(ctx, "SELECT pgmq.delete($1, $2::bigint)", PGMQRequestQueue, m.id)
	}
	if err == nil {
		err = tx.Commit(ctx)
	}
	if err != nil {
		slog.Error("cannot send reply", "error", err, "msgId", m.id, "correlationId", h.CorrelationID)
	}
}

func deleteRequest(pool *pgxpool.Pool, m pgmqMessage) {
	ctx, cancel := context.WithTimeout(context.Background(), dbTimeout)
	defer cancel()
	if _, err := pool.Exec(ctx, "SELECT pgmq.delete($1, $2::bigint)", PGMQRequestQueue, m.id); err != nil {
		slog.Error("cannot delete request", "error", err, "msgId", m.id)
	}
}
