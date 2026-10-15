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
	body, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	id := rand.Text()
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
			_, err = tx.Exec(ctx, `INSERT INTO sync_queue.requests(id,request,deadline) VALUES($1,$2,$3)`, id, body, deadline)
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
		err = conn.QueryRow(ctx, `DELETE FROM sync_queue.requests WHERE id=$1 AND completed AND deadline>statement_timestamp() RETURNING response`, id).Scan(&response)
		if err == nil {
			var reply syncprotocol.Response
			if err = json.Unmarshal(response, &reply); err != nil {
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

func Cleanup(ctx context.Context, pool *pgxpool.Pool) {
	clean := func() {
		cleanupCtx, cancel := context.WithTimeout(ctx, cleanupTimeout)
		defer cancel()
		for _, query := range []string{`DELETE FROM sync_queue.requests WHERE deadline<=statement_timestamp()`, `DELETE FROM sessions WHERE expires_at<=statement_timestamp()`} {
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
