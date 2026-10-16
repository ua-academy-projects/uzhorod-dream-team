package postgresqueue

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"time"

	"fetcher/internal/syncprotocol"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Worker struct {
	pool    *pgxpool.Pool
	handler syncprotocol.Handler
}

func NewWorker(pool *pgxpool.Pool, handler syncprotocol.Handler) *Worker {
	return &Worker{pool: pool, handler: handler}
}

func (w *Worker) Run(ctx context.Context) {
	for ctx.Err() == nil {
		conn, err := listen(ctx, w.pool, requestsChannel)
		if err == nil {
			log.Print("Fetcher PostgreSQL queue connected")
			err = w.consume(ctx, conn)
			closeConnection(conn)
		}
		if ctx.Err() != nil {
			return
		}
		log.Printf("Fetcher PostgreSQL queue interrupted: %v; reconnecting", err)
		if !wait(ctx) {
			return
		}
	}
}

func (w *Worker) consume(ctx context.Context, conn *pgx.Conn) error {
	for ctx.Err() == nil {
		processed, err := w.process(ctx)
		if err != nil {
			return err
		}
		if processed {
			continue
		}
		if _, err = conn.WaitForNotification(ctx); err != nil {
			return err
		}
	}
	return ctx.Err()
}

func (w *Worker) process(ctx context.Context) (bool, error) {
	tx, err := w.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer func() {
		rollbackCtx, cancel := context.WithTimeout(context.Background(), connectionTimeout)
		defer cancel()
		_ = tx.Rollback(rollbackCtx)
	}()
	var body []byte
	err = tx.QueryRow(ctx, `SELECT message FROM pgmq.pop($1,1)`, requestsChannel).Scan(&body)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var envelope message
	if err = json.Unmarshal(body, &envelope); err != nil || envelope.CorrelationID == "" || envelope.Deadline.IsZero() {
		log.Print("Discarding invalid PostgreSQL queue message")
		return true, tx.Commit(ctx)
	}
	if !envelope.Deadline.After(time.Now()) {
		return true, tx.Commit(ctx)
	}
	requestCtx, cancel := context.WithDeadline(ctx, envelope.Deadline)
	defer cancel()
	var request syncprotocol.Request
	response := syncprotocol.Response{Version: syncprotocol.Version}
	if err = json.Unmarshal(envelope.Payload, &request); err == nil {
		response.Data, err = w.handler.Handle(requestCtx, request)
	}
	if requestCtx.Err() != nil {
		return false, requestCtx.Err()
	}
	if err != nil {
		response.Data = nil
		response.Error = err.Error()
	}
	reply, err := json.Marshal(response)
	if err != nil {
		return false, err
	}
	body, err = json.Marshal(message{CorrelationID: envelope.CorrelationID, Deadline: envelope.Deadline, Payload: reply})
	if err != nil {
		return false, err
	}
	if _, err = tx.Exec(requestCtx, `SELECT pgmq.send($1,$2::jsonb)`, repliesChannel, body); err != nil {
		return false, err
	}
	if _, err = tx.Exec(requestCtx, `SELECT pg_notify($1,$2)`, repliesChannel, envelope.CorrelationID); err != nil {
		return false, err
	}
	return true, tx.Commit(requestCtx)
}
