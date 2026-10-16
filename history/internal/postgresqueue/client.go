package postgresqueue

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"time"

	"history/internal/syncprotocol"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const cleanupInterval = 15 * time.Minute
const cleanupTimeout = 5 * time.Second

type Client struct{ pool *pgxpool.Pool }

func NewClient(pool *pgxpool.Pool) *Client { return &Client{pool: pool} }

func (c *Client) Call(ctx context.Context, request syncprotocol.Request) (json.RawMessage, error) {
	deadline, ok := ctx.Deadline()
	if !ok {
		return nil, errors.New("PostgreSQL request requires a deadline")
	}
	request.Version = syncprotocol.Version
	request.Deadline = deadline
	payload, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	id := rand.Text()
	body, err := json.Marshal(message{CorrelationID: id, Deadline: deadline, Payload: payload})
	if err != nil {
		return nil, err
	}
	filter, err := json.Marshal(map[string]string{"correlation_id": id})
	if err != nil {
		return nil, err
	}
	var conn *pgxpool.Conn
	defer func() {
		if conn != nil {
			releaseConnection(conn)
		}
	}()
	inserted := false
	for ctx.Err() == nil {
		if conn == nil {
			conn, err = listen(ctx, c.pool, repliesChannel)
			if err != nil {
				if !wait(ctx) {
					break
				}
				continue
			}
		}
		if !inserted {
			tx, err := conn.Begin(ctx)
			if err != nil {
				return nil, err
			}
			_, err = tx.Exec(ctx, `SELECT pgmq.send($1,$2::jsonb)`, requestsChannel, body)
			if err == nil {
				_, err = tx.Exec(ctx, `SELECT pg_notify($1,$2)`, requestsChannel, id)
			}
			if err == nil {
				err = tx.Commit(ctx)
			} else {
				rollbackCtx, cancel := context.WithTimeout(context.Background(), connectionTimeout)
				_ = tx.Rollback(rollbackCtx)
				cancel()
			}
			if err != nil {
				return nil, err
			}
			inserted = true
		}
		var response []byte
		response, err = receiveReply(ctx, conn, filter)
		if err == nil {
			var envelope message
			if err = json.Unmarshal(response, &envelope); err != nil {
				return nil, err
			}
			var reply syncprotocol.Response
			if err = json.Unmarshal(envelope.Payload, &reply); err != nil {
				return nil, err
			}
			if reply.Version != syncprotocol.Version {
				return nil, errors.New("unsupported Fetcher reply version")
			}
			if reply.Error != "" {
				return nil, fmt.Errorf("Fetcher: %s", reply.Error)
			}
			if len(reply.Data) == 0 {
				return nil, errors.New("Fetcher reply contains no data")
			}
			return reply.Data, nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			releaseConnection(conn)
			conn = nil
			if !wait(ctx) {
				break
			}
			continue
		}
		if _, err = conn.Conn().WaitForNotification(ctx); err != nil {
			releaseConnection(conn)
			conn = nil
			if !wait(ctx) {
				break
			}
		}
	}
	return nil, ctx.Err()
}

func receiveReply(ctx context.Context, conn *pgxpool.Conn, filter []byte) ([]byte, error) {
	tx, err := conn.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() {
		rollbackCtx, cancel := context.WithTimeout(context.Background(), connectionTimeout)
		defer cancel()
		_ = tx.Rollback(rollbackCtx)
	}()
	var id int64
	var body []byte
	err = tx.QueryRow(ctx, `SELECT msg_id,message FROM pgmq.read($1,0,1,$2::jsonb) WHERE (message->>'deadline')::timestamptz>statement_timestamp()`, repliesChannel, filter).Scan(&id, &body)
	if err != nil {
		return nil, err
	}
	var deleted bool
	if err = tx.QueryRow(ctx, `SELECT pgmq.delete($1,$2::bigint)`, repliesChannel, id).Scan(&deleted); err != nil {
		return nil, err
	}
	if !deleted {
		return nil, errors.New("PostgreSQL reply disappeared before acknowledgement")
	}
	if err = tx.Commit(ctx); err != nil {
		return nil, err
	}
	return body, nil
}

func Cleanup(ctx context.Context, pool *pgxpool.Pool) {
	clean := func() {
		cleanupCtx, cancel := context.WithTimeout(ctx, cleanupTimeout)
		defer cancel()
		for _, query := range []string{
			`SELECT pgmq.delete('kyiv_air_requests',msg_id) FROM pgmq.q_kyiv_air_requests WHERE (message->>'deadline')::timestamptz<=statement_timestamp()`,
			`SELECT pgmq.delete('kyiv_air_replies',msg_id) FROM pgmq.q_kyiv_air_replies WHERE (message->>'deadline')::timestamptz<=statement_timestamp()`,
			`DELETE FROM sessions WHERE expires_at<=statement_timestamp()`,
		} {
			if _, err := pool.Exec(cleanupCtx, query); err != nil && ctx.Err() == nil {
				log.Printf("PostgreSQL transient data cleanup failed: %v", err)
			}
		}
	}
	clean()
	ticker := time.NewTicker(cleanupInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			clean()
		}
	}
}
