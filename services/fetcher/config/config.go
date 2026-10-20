package config

import (
	"fetcher/internal/model"
	"os"
)

type Address struct {
	Host string
	Port string
}

type RabbitMQ struct {
	Address
	User     string
	Password string
}

type PSQL struct {
	Address
	User     string
	Password string
	Database string
}

type Config struct {
	Host string
	Port string

	QueueType model.QueueType

	RabbitMQ RabbitMQ

	PSQL PSQL
}

func LoadConfig() *Config {
	return &Config{
		Host: os.Getenv("FETCHER_HOST"),
		Port: os.Getenv("FETCHER_PORT"),

		RabbitMQ: RabbitMQ{
			Address: Address{
				Host: os.Getenv("RABBITMQ_HOST"),
				Port: os.Getenv("RABBITMQ_PORT"),
			},
			User:     os.Getenv("RABBITMQ_USER"),
			Password: os.Getenv("RABBITMQ_PASSWORD"),
		},

		PSQL: PSQL{
			Address: Address{
				Host: os.Getenv("DATABASE_HOST"),
				Port: os.Getenv("DATABASE_PORT"),
			},
			User:     os.Getenv("DATABASE_USER"),
			Password: os.Getenv("DATABASE_PASSWORD"),
			Database: os.Getenv("DATABASE_DB"),
		},

		QueueType: model.QueueType(os.Getenv("QUEUE_TYPE")),
	}
}
