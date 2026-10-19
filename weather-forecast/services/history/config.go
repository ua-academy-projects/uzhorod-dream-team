package main

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	backendRabbitMQRedis = "rabbitmq_redis"
	backendPostgres      = "postgres"
)

type Config struct {
	Backend             string
	RedisAddr           string
	RedisPassword       string
	SessionCookieSecure bool
	DatabaseURL         string
	RabbitMQURL         string
	City                string
	Latitude, Longitude float64
	JobTimeout          time.Duration
	Address             string
	UIDir               string
	Interval            time.Duration
	TemperatureInterval time.Duration
	TemperatureDays     int
}

func envOr(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func loadConfig() (Config, error) {
	c := Config{
		Backend:       envOr("WEATHER_BACKEND", backendRabbitMQRedis),
		RedisAddr:     envOr("REDIS_ADDR", "127.0.0.1:6379"),
		RedisPassword: os.Getenv("REDIS_PASSWORD"),
		DatabaseURL:   os.Getenv("DATABASE_URL"),
		RabbitMQURL:   os.Getenv("RABBITMQ_URL"),
		City:          envOr("CITY_NAME", "Uzhhorod"),
		Address:       envOr("HISTORY_ADDR", "127.0.0.1:8002"),
		UIDir:         envOr("UI_DIR", "../ui/public"),
	}
	if c.DatabaseURL == "" {
		return c, fmt.Errorf("DATABASE_URL is required")
	}
	if c.Backend != backendRabbitMQRedis && c.Backend != backendPostgres {
		return c, fmt.Errorf("WEATHER_BACKEND must be rabbitmq_redis or postgres")
	}
	if c.Backend == backendRabbitMQRedis {
		u, err := url.Parse(c.RabbitMQURL)
		if err != nil || (u.Scheme != "amqp" && u.Scheme != "amqps") || u.Host == "" || u.Fragment != "" {
			return c, fmt.Errorf("RABBITMQ_URL must be an AMQP(S) URL")
		}
		if _, _, err := net.SplitHostPort(c.RedisAddr); err != nil {
			return c, fmt.Errorf("REDIS_ADDR must be host:port")
		}
	}
	var err error
	c.SessionCookieSecure, err = strconv.ParseBool(envOr("SESSION_COOKIE_SECURE", "false"))
	if err != nil {
		return c, fmt.Errorf("SESSION_COOKIE_SECURE must be true or false")
	}
	c.Latitude, err = strconv.ParseFloat(envOr("CITY_LATITUDE", "48.6167"), 64)
	if err != nil || !finite(c.Latitude) || c.Latitude < -90 || c.Latitude > 90 {
		return c, fmt.Errorf("invalid CITY_LATITUDE")
	}
	c.Longitude, err = strconv.ParseFloat(envOr("CITY_LONGITUDE", "22.3"), 64)
	if err != nil || !finite(c.Longitude) || c.Longitude < -180 || c.Longitude > 180 {
		return c, fmt.Errorf("invalid CITY_LONGITUDE")
	}
	if strings.TrimSpace(c.City) == "" || len([]rune(c.City)) > 100 {
		return c, fmt.Errorf("invalid CITY_NAME")
	}
	c.JobTimeout, err = time.ParseDuration(envOr("JOB_TIMEOUT", "120s"))
	if err != nil || c.JobTimeout < time.Second || c.JobTimeout > 10*time.Minute {
		return c, fmt.Errorf("JOB_TIMEOUT must be between 1s and 10m")
	}
	if _, _, err := net.SplitHostPort(c.Address); err != nil {
		return c, fmt.Errorf("invalid HISTORY_ADDR: %w", err)
	}
	c.Interval, err = time.ParseDuration(envOr("COLLECT_INTERVAL", "15m"))
	if err != nil || c.Interval < time.Second {
		return c, fmt.Errorf("COLLECT_INTERVAL must be a duration >= 1s, e.g. 15m or 30s")
	}
	c.TemperatureInterval, err = time.ParseDuration(envOr("TEMPERATURE_SYNC_INTERVAL", "1h"))
	if err != nil || c.TemperatureInterval < time.Second {
		return c, fmt.Errorf("TEMPERATURE_SYNC_INTERVAL must be a duration >= 1s")
	}
	c.TemperatureDays, err = strconv.Atoi(envOr("TEMPERATURE_HISTORY_DAYS", "30"))
	if err != nil || c.TemperatureDays < 1 || c.TemperatureDays > 92 {
		return c, fmt.Errorf("TEMPERATURE_HISTORY_DAYS must be between 1 and 92")
	}
	serveUI, err := strconv.ParseBool(envOr("HISTORY_SERVE_UI", "true"))
	if err != nil {
		return c, fmt.Errorf("HISTORY_SERVE_UI must be true or false")
	}
	if serveUI {
		if info, err := os.Stat(c.UIDir + "/index.html"); err != nil || info.IsDir() {
			return c, fmt.Errorf("UI_DIR must contain index.html (current default is ../ui/public)")
		}
	} else {
		c.UIDir = ""
	}
	return c, nil
}
