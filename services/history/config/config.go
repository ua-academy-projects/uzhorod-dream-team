package config

import (
	"history/internal/model"
	"os"
)

type Address struct {
	Host string
	Port string
}

type PSQL struct {
	Address
	User     string
	Password string
	Database string
}

type Redis struct {
	Address
	Password string
}

type RabbitMQ struct {
	Address
	User     string
	Password string
}

type Config struct {
	Host string
	Port string

	PSQL     PSQL
	Redis    Redis
	RabbitMQ RabbitMQ

	QueueType model.QueueType
	CacheType model.CacheType
}

func LoadConfig() *Config {
	return &Config{
		Host: os.Getenv("HISTORY_HOST"),
		Port: os.Getenv("HISTORY_PORT"),

		PSQL: PSQL{
			Address: Address{
				Host: os.Getenv("DATABASE_HOST"),
				Port: os.Getenv("DATABASE_PORT"),
			},
			User:     os.Getenv("DATABASE_USER"),
			Password: os.Getenv("DATABASE_PASSWORD"),
			Database: os.Getenv("DATABASE_DB"),
		},

		Redis: Redis{
			Address: Address{
				Host: os.Getenv("REDIS_HOST"),
				Port: os.Getenv("REDIS_PORT"),
			},
			Password: os.Getenv("REDIS_PASSWORD"),
		},

		RabbitMQ: RabbitMQ{
			Address: Address{
				Host: os.Getenv("RABBITMQ_HOST"),
				Port: os.Getenv("RABBITMQ_PORT"),
			},
			User:     os.Getenv("RABBITMQ_USER"),
			Password: os.Getenv("RABBITMQ_PASSWORD"),
		},

		QueueType: model.QueueType(os.Getenv("QUEUE_TYPE")),
		CacheType: model.CacheType(os.Getenv("CACHE_TYPE")),
	}
}
