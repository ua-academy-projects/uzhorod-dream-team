package main

import "testing"

func TestBackendConfiguration(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://localhost/weather_history")
	t.Setenv("HISTORY_SERVE_UI", "false")
	t.Setenv("RABBITMQ_URL", "amqp://localhost/")
	t.Setenv("WEATHER_BACKEND", "")
	config, err := loadConfig()
	if err != nil || config.Backend != backendRabbitMQRedis {
		t.Fatalf("default backend: %v", err)
	}
	t.Setenv("WEATHER_BACKEND", "postgres")
	t.Setenv("RABBITMQ_URL", "unused-invalid-url")
	t.Setenv("REDIS_ADDR", "localhost:6379")
	config, err = loadConfig()
	if err != nil || config.Backend != backendPostgres {
		t.Fatalf("PostgreSQL required an unused backend: %v", err)
	}
	t.Setenv("WEATHER_BACKEND", "invalid")
	if _, err := loadConfig(); err == nil {
		t.Fatal("unknown backend accepted")
	}
}
