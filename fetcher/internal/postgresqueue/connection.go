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

func listen(ctx context.Context, pool *pgxpool.Pool, channel string) (*pgx.Conn, error) {
	connectCtx, cancel := context.WithTimeout(ctx, connectionTimeout)
	defer cancel()
	conn, err := pgx.ConnectConfig(connectCtx, pool.Config().ConnConfig.Copy())
	if err != nil {
		return nil, err
	}
	if _, err = conn.Exec(connectCtx, "LISTEN "+pgx.Identifier{channel}.Sanitize()); err != nil {
		closeConnection(conn)
		return nil, err
	}
	return conn, nil
}

func closeConnection(conn *pgx.Conn) {
	ctx, cancel := context.WithTimeout(context.Background(), connectionTimeout)
	defer cancel()
	_ = conn.Close(ctx)
}

func wait(ctx context.Context) bool {
	select {
	case <-ctx.Done():
		return false
	case <-time.After(reconnectInterval):
		return true
	}
}
