package config

import (
	"os"
	"strings"
	"time"

	"github.com/joho/godotenv"
)

type Config struct {
	Environment             string
	Port                    string
	DatabaseURL             string
	FetcherServiceURL       string
	SyncInterval            time.Duration
	BackfillThreshold       time.Duration
	DefaultBackfillDuration time.Duration
	FetcherTimeout          time.Duration
	AllowedOrigins          []string
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
		port = "8081"
	}

	dbURL := os.Getenv("DATABASE_URL")

	fetcherURL := os.Getenv("FETCHER_SERVICE_URL")
	if fetcherURL == "" {
		fetcherURL = "http://localhost:8080"
	}

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

	fetcherTimeoutStr := os.Getenv("FETCHER_TIMEOUT")
	fetcherTimeout := time.Minute
	if fetcherTimeoutStr != "" {
		if t, err := time.ParseDuration(fetcherTimeoutStr); err == nil {
			fetcherTimeout = t
		}
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

	return &Config{
		Environment:             env,
		Port:                    port,
		DatabaseURL:             dbURL,
		FetcherServiceURL:       fetcherURL,
		SyncInterval:            syncInterval,
		BackfillThreshold:       backfillThreshold,
		DefaultBackfillDuration: defaultBackfillDuration,
		FetcherTimeout:          fetcherTimeout,
		AllowedOrigins:          allowedOrigins,
	}
}
