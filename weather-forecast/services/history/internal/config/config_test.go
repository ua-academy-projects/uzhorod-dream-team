package config

import "testing"

func TestBackendConfiguration(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://localhost/weather_history")
	t.Setenv("HISTORY_SERVE_UI", "false")
	t.Setenv("RABBITMQ_URL", "amqp://localhost/")
	t.Setenv("WEATHER_BACKEND", "")
	cfg, err := Load()
	if err != nil || cfg.Backend != BackendRabbitMQRedis {
		t.Fatalf("default backend: %v", err)
	}
	t.Setenv("WEATHER_BACKEND", "postgres")
	t.Setenv("RABBITMQ_URL", "unused-invalid-url")
	t.Setenv("REDIS_ADDR", "unused-invalid-address")
	cfg, err = Load()
	if err != nil || cfg.Backend != BackendPostgres {
		t.Fatalf("PostgreSQL required an unused backend: %v", err)
	}
	t.Setenv("WEATHER_BACKEND", "invalid")
	if _, err := Load(); err == nil {
		t.Fatal("unknown backend accepted")
	}
}
