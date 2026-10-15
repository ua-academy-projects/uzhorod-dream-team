package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/joho/godotenv"
)

type Config struct {
	PostgresOnly            bool
	Environment             string
	Port                    string
	DatabaseURL             string
	RabbitMQ                RabbitMQ
	SyncInterval            time.Duration
	BackfillThreshold       time.Duration
	DefaultBackfillDuration time.Duration
	FetcherTimeout          time.Duration
	AllowedOrigins          []string
	RedisURL                string
	SessionTTL              time.Duration
	SessionCookieSecure     bool
	SessionStoreTimeout     time.Duration
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
		port = "8081"
	}

	dbURL := os.Getenv("DATABASE_URL")

	syncIntervalStr := os.Getenv("SYNC_INTERVAL")
	syncInterval := 15 * time.Minute
	if syncIntervalStr != "" {
		if t, err := time.ParseDuration(syncIntervalStr); err == nil {
			syncInterval = t
		}
	}

	backfillThresholdStr := os.Getenv("BACKFILL_THRESHOLD")
	backfillThreshold := 1 * time.Hour
	if backfillThresholdStr != "" {
		if t, err := time.ParseDuration(backfillThresholdStr); err == nil {
			backfillThreshold = t
		}
	}

	defaultBackfillDurationStr := os.Getenv("DEFAULT_BACKFILL_DURATION")
	defaultBackfillDuration := 720 * time.Hour // ~30 days
	if defaultBackfillDurationStr != "" {
		if t, err := time.ParseDuration(defaultBackfillDurationStr); err == nil {
			defaultBackfillDuration = t
		}
	}

	fetcherTimeout := time.Minute
	if value, err := time.ParseDuration(os.Getenv("FETCHER_TIMEOUT")); err == nil && value > 0 {
		fetcherTimeout = value
	}

	allowedOriginsStr := os.Getenv("ALLOWED_ORIGINS")
	var allowedOrigins []string
	if allowedOriginsStr != "" {
		parts := strings.Split(allowedOriginsStr, ",")
		for _, p := range parts {
			allowedOrigins = append(allowedOrigins, strings.TrimSpace(p))
		}
	} else {
		allowedOrigins = []string{"http://localhost:5173", "http://localhost:3000", "http://localhost:80"}
	}

	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		redisURL = "redis://localhost:6379/0"
	}
	sessionTTL := positiveDuration("SESSION_TTL", 720*time.Hour)
	sessionTimeout := positiveDuration("SESSION_STORE_TIMEOUT", positiveDuration("SESSION_REDIS_TIMEOUT", time.Second))
	sessionSecure := env != "development"
	if value, err := strconv.ParseBool(os.Getenv("SESSION_COOKIE_SECURE")); err == nil {
		sessionSecure = value
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
		PostgresOnly:            postgresOnly,
		Environment:             env,
		Port:                    port,
		DatabaseURL:             dbURL,
		RabbitMQ:                loadRabbitMQ(),
		SyncInterval:            syncInterval,
		BackfillThreshold:       backfillThreshold,
		DefaultBackfillDuration: defaultBackfillDuration,
		FetcherTimeout:          fetcherTimeout,
		AllowedOrigins:          allowedOrigins,
		RedisURL:                redisURL,
		SessionTTL:              sessionTTL,
		SessionCookieSecure:     sessionSecure,
		SessionStoreTimeout:     sessionTimeout,
	}, nil
}

func positiveDuration(name string, fallback time.Duration) time.Duration {
	if value, err := time.ParseDuration(os.Getenv(name)); err == nil && value >= time.Second {
		return value
	}
	return fallback
}
