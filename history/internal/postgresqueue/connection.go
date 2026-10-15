package postgresqueue

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	requestsChannel   = "kyiv_air_requests"
	repliesChannel    = "kyiv_air_replies"
	reconnectInterval = 5 * time.Second
	connectionTimeout = 5 * time.Second
)

func listen(ctx context.Context, pool *pgxpool.Pool, channel string) (*pgxpool.Conn, error) {
	connectCtx, cancel := context.WithTimeout(ctx, connectionTimeout)
	defer cancel()
	conn, err := pool.Acquire(connectCtx)
	if err != nil {
		return nil, err
	}
	if _, err = conn.Exec(connectCtx, "LISTEN "+pgx.Identifier{channel}.Sanitize()); err != nil {
		releaseConnection(conn)
		return nil, err
	}
	return conn, nil
}

func releaseConnection(conn *pgxpool.Conn) {
	ctx, cancel := context.WithTimeout(context.Background(), connectionTimeout)
	defer cancel()
	if _, err := conn.Exec(ctx, "UNLISTEN *"); err != nil {
		_ = conn.Conn().Close(ctx)
	}
	conn.Release()
}

func wait(ctx context.Context) bool {
	select {
	case <-ctx.Done():
		return false
	case <-time.After(reconnectInterval):
		return true
	}
}
