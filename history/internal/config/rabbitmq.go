package config

import (
	"os"
	"time"
)

type RabbitMQ struct {
	URL               string
	RequestQueue      string
	ConnectionTimeout time.Duration
	ReconnectInterval time.Duration
}

func loadRabbitMQ() RabbitMQ {
	return RabbitMQ{
		URL:               rabbitMQValue("RABBITMQ_URL", "amqp://guest:guest@localhost:5672/"),
		RequestQueue:      rabbitMQValue("RABBITMQ_REQUEST_QUEUE", "fetcher.sync.requests.v1"),
		ConnectionTimeout: rabbitMQDuration("RABBITMQ_CONNECTION_TIMEOUT", 5*time.Second),
		ReconnectInterval: rabbitMQDuration("RABBITMQ_RECONNECT_INTERVAL", 5*time.Second),
	}
}

func rabbitMQValue(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func rabbitMQDuration(name string, fallback time.Duration) time.Duration {
	if value, err := time.ParseDuration(os.Getenv(name)); err == nil && value > 0 {
		return value
	}
	return fallback
}
