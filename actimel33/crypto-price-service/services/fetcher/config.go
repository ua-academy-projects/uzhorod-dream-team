package main

import (
	"fmt"
	"os"
	"strconv"
)

// Config is assembled once at startup. A missing required variable is a reason
// to fail right away rather than on the first request.
type Config struct {
	Host              string
	Port              int
	CoinGeckoBaseURL  string
	QueueDriver       string
	QueueDatabaseURL  string
	RedisURL          string
	RedisPassword     string
	TimerIntervalHrs  float64
	HTTPTimeoutMillis int
	RetryAttempts     int
	DefaultCoin       string
	DefaultVs         string
}

func LoadConfig() (*Config, error) {
	// Each driver needs only its own connection settings.
	driver := envStr("QUEUE_DRIVER", "redis")
	redisPassword := os.Getenv("REDIS_PASSWORD")
	queueURL := os.Getenv("QUEUE_DATABASE_URL")
	switch driver {
	case "redis":
		if redisPassword == "" {
			return nil, fmt.Errorf("missing required env: REDIS_PASSWORD")
		}
	case "postgres":
		if queueURL == "" {
			return nil, fmt.Errorf("missing required env: QUEUE_DATABASE_URL")
		}
	default:
		return nil, fmt.Errorf("env QUEUE_DRIVER must be redis or postgres, got %q", driver)
	}

	port, err := envInt("FETCHER_PORT", 3002)
	if err != nil {
		return nil, err
	}
	timeout, err := envInt("HTTP_TIMEOUT_MS", 10000)
	if err != nil {
		return nil, err
	}
	attempts, err := envInt("RETRY_ATTEMPTS", 3)
	if err != nil {
		return nil, err
	}
	interval, err := envFloat("TIMER_INTERVAL_HOURS", 12)
	if err != nil {
		return nil, err
	}

	return &Config{
		// Loopback by default. On a dedicated VM the peers live elsewhere,
		// so the address is configurable rather than hard-coded.
		Host:              envStr("FETCHER_HOST", "127.0.0.1"),
		Port:              port,
		CoinGeckoBaseURL:  envStr("COINGECKO_BASE_URL", "https://api.coingecko.com/api/v3"),
		QueueDriver:       driver,
		QueueDatabaseURL:  queueURL,
		RedisURL:          envStr("REDIS_URL", "redis://localhost:6379"),
		RedisPassword:     redisPassword,
		TimerIntervalHrs:  interval,
		HTTPTimeoutMillis: timeout,
		RetryAttempts:     attempts,
		DefaultCoin:       envStr("DEFAULT_COIN", "bitcoin"),
		DefaultVs:         envStr("DEFAULT_VS", "usd"),
	}, nil
}

func envStr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func envInt(name string, fallback int) (int, error) {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback, nil
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("env %s must be an integer, got %q", name, raw)
	}
	return v, nil
}

func envFloat(name string, fallback float64) (float64, error) {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback, nil
	}
	v, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return 0, fmt.Errorf("env %s must be a number, got %q", name, raw)
	}
	return v, nil
}
