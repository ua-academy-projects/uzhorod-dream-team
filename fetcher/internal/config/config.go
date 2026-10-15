package config

import (
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/joho/godotenv"
)

type Config struct {
	PostgresOnly bool
	DatabaseURL  string

	Environment  string
	Port         string
	OpenAQURL    string
	OpenAQAPIKey string
	HTTPTimeout  time.Duration
	RabbitMQ     RabbitMQ
}

func Load() (*Config, error) {
	env := os.Getenv("ENVIRONMENT")
	if env == "" {
		env = "development"
	}

	_ = godotenv.Load(".env." + env)
	_ = godotenv.Load(".env")

	if loadedEnv := os.Getenv("ENVIRONMENT"); loadedEnv != "" {
		env = loadedEnv
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	openaqURL := os.Getenv("OPENAQ_URL")
	if openaqURL == "" {
		openaqURL = "https://api.openaq.org"
	}

	timeoutStr := os.Getenv("HTTP_TIMEOUT")
	timeout := 10 * time.Second
	if timeoutStr != "" {
		if t, err := time.ParseDuration(timeoutStr); err == nil {
			timeout = t
		}
	}

	postgresOnly := false
	if value := os.Getenv("POSTGRES_ONLY"); value != "" {
		var err error
		postgresOnly, err = strconv.ParseBool(value)
		if err != nil {
			return nil, fmt.Errorf("invalid POSTGRES_ONLY: %q", value)
		}
	}
	if postgresOnly && os.Getenv("DATABASE_URL") == "" {
		return nil, fmt.Errorf("DATABASE_URL is required when POSTGRES_ONLY=true")
	}
	return &Config{
		PostgresOnly: postgresOnly,
		DatabaseURL:  os.Getenv("DATABASE_URL"),
		Environment:  env,
		Port:         port,
		OpenAQURL:    openaqURL,
		OpenAQAPIKey: os.Getenv("OPENAQ_API_KEY"),
		HTTPTimeout:  timeout,
		RabbitMQ:     loadRabbitMQ(),
	}, nil
}
