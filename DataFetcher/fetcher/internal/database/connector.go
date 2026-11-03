package database

import (
	"context"
	"net"

	"cloud.google.com/go/cloudsqlconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// PoolConfig keeps direct PostgreSQL connections available for local development.
// When instance is set, every connection uses the Cloud SQL private IP connector.
func PoolConfig(ctx context.Context, dsn, instance string) (*pgxpool.Config, func(), error) {
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, nil, err
	}
	if instance == "" {
		return config, func() {}, nil
	}
	dialer, err := cloudsqlconn.NewDialer(ctx, cloudsqlconn.WithLazyRefresh())
	if err != nil {
		return nil, nil, err
	}
	// The connector provides authenticated TLS; disable the driver's TLS layer.
	config.ConnConfig.TLSConfig = nil
	config.ConnConfig.Fallbacks = nil
	config.ConnConfig.DialFunc = func(ctx context.Context, _, _ string) (net.Conn, error) {
		return dialer.Dial(ctx, instance, cloudsqlconn.WithPrivateIP())
	}
	return config, func() { _ = dialer.Close() }, nil
}
