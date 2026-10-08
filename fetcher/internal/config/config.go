package config

import (
	"os"
	"time"

	"github.com/joho/godotenv"
)

type Config struct {
	Environment  string
	Port         string
	OpenAQURL    string
	OpenAQAPIKey string
	HTTPTimeout  time.Duration
	RabbitMQ     RabbitMQ
}

func Load() *Config {
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

	return &Config{
		Environment:  env,
		Port:         port,
		OpenAQURL:    openaqURL,
		OpenAQAPIKey: os.Getenv("OPENAQ_API_KEY"),
		HTTPTimeout:  timeout,
		RabbitMQ:     loadRabbitMQ(),
	}
}
