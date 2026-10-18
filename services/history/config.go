package main

import (
	"log/slog"
	"net"
	"net/url"
	"os"
	"slices"
	"strconv"
	"time"
)

type Config struct {
	PostgresHost     string
	PostgresPort     string
	PostgresUser     string
	PostgresPassword string
	PostgresDB       string
	FetcherRole      string
	QueueBackend     string
	SessionBackend   string
	RabbitMQURL      string
	RabbitMQAddr     string
	RabbitMQQueue    string
	RedisAddr        string
	RedisPassword    string
	Port             string
	ResultLimit      int
	SessionTTL       time.Duration
}

func loadConfig() Config {
	limit, err := strconv.Atoi(mustEnv("HISTORY_RESULT_LIMIT"))
	if err != nil || limit <= 0 {
		fatal("HISTORY_RESULT_LIMIT must be a positive integer", "err", err)
	}
	ttl, err := time.ParseDuration(mustEnv("HISTORY_SESSION_TTL"))
	if err != nil || ttl <= 0 {
		fatal("HISTORY_SESSION_TTL must be a positive Go duration (e.g. 720h)", "err", err)
	}

	c := Config{
		PostgresHost:     mustEnv("POSTGRES_HOST"),
		PostgresPort:     mustEnv("POSTGRES_PORT"),
		PostgresUser:     mustEnv("POSTGRES_USER"),
		PostgresPassword: mustEnv("POSTGRES_PASSWORD"),
		PostgresDB:       mustEnv("POSTGRES_DB"),
		FetcherRole:      mustEnv("POSTGRES_FETCHER_USER"),
		QueueBackend:     mustOneOf("QUEUE_BACKEND", "rabbitmq", "postgres", "pgmq"),
		SessionBackend:   mustOneOf("SESSION_BACKEND", "redis", "postgres", "hstore"),
		Port:             mustEnv("HISTORY_PORT"),
		ResultLimit:      limit,
		SessionTTL:       ttl,
	}

	if c.QueueBackend == "rabbitmq" {
		c.RabbitMQAddr = net.JoinHostPort(mustEnv("RABBITMQ_HOST"), mustEnv("RABBITMQ_PORT"))
		rabbitURL := url.URL{
			Scheme: "amqp",
			User:   url.UserPassword(mustEnv("RABBITMQ_USER"), mustEnv("RABBITMQ_PASSWORD")),
			Host:   c.RabbitMQAddr,
			Path:   "/",
		}
		c.RabbitMQURL = rabbitURL.String()
		c.RabbitMQQueue = mustEnv("RABBITMQ_QUEUE")
	}
	if c.SessionBackend == "redis" {
		c.RedisAddr = net.JoinHostPort(mustEnv("REDIS_HOST"), mustEnv("REDIS_PORT"))
		c.RedisPassword = mustEnv("REDIS_PASSWORD")
	}
	return c
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		fatal("missing required environment variable", "key", key)
	}
	return v
}

func mustOneOf(key string, allowed ...string) string {
	v := mustEnv(key)
	if !slices.Contains(allowed, v) {
		fatal("invalid environment variable value", "key", key, "value", v, "allowed", allowed)
	}
	return v
}

func fatal(msg string, args ...any) {
	slog.Error(msg, args...)
	os.Exit(1)
}
