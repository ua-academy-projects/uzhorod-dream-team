package model

import (
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

type CacheType string

const (
	CacheRedis  CacheType = "redis"
	CacheHStore CacheType = "hstore"
)

type QueueType string

const (
	QueueRabbitMQ QueueType = "rabbitmq"
	QueuePGMQ     QueueType = "pgmq"
)

type Dependencies struct {
	Postgres  *pgxpool.Pool
	Redis     *redis.Client
	CacheType CacheType
}
