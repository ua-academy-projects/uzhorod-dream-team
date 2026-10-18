package main

import (
	"context"
	"database/sql"
	"log/slog"
	"net"
	"net/http"
	"os"
)

type ISSData struct {
	Name       string  `json:"name"`
	ID         int     `json:"id"`
	Latitude   float64 `json:"latitude"`
	Longitude  float64 `json:"longitude"`
	Altitude   float64 `json:"altitude"`
	Velocity   float64 `json:"velocity"`
	Visibility string  `json:"visibility"`
	Footprint  float64 `json:"footprint"`
	Timestamp  int64   `json:"timestamp"`
	Daynum     float64 `json:"daynum"`
	SolarLat   float64 `json:"solar_lat"`
	SolarLon   float64 `json:"solar_lon"`
	Units      string  `json:"units"`
}

var cfg Config
var db *sql.DB
var dbURL string
var sessions SessionStore
var ctx = context.Background()

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, nil)))
	cfg = loadConfig()

	slog.Info("history starting",
		"port", cfg.Port,
		"postgres", net.JoinHostPort(cfg.PostgresHost, cfg.PostgresPort), "database", cfg.PostgresDB,
		"queue_backend", cfg.QueueBackend, "session_backend", cfg.SessionBackend)

	initDB()
	migrate()
	sessions = newSessionStore()

	switch cfg.QueueBackend {
	case "postgres":
		go consumePostgresQueue()
	case "pgmq":
		go consumePgmq()
	default:
		go consumeRabbitMQ()
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/history", GetHistory)
	mux.HandleFunc("/settings", SettingsHandler)
	mux.HandleFunc("/passes", PassesHandler)

	slog.Info("http server listening", "addr", "0.0.0.0:"+cfg.Port)
	if err := http.ListenAndServe("0.0.0.0:"+cfg.Port, accessLog(mux)); err != nil {
		fatal("http server stopped", "err", err)
	}
}
