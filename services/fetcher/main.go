package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"slices"
	"time"

	_ "github.com/lib/pq"
	amqp "github.com/rabbitmq/amqp091-go"
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

type Config struct {
	ISSAPIURL     string
	PollInterval  time.Duration
	QueueBackend  string
	RabbitMQURL   string
	RabbitMQAddr  string
	RabbitMQQueue string
	PostgresURL   string
	PostgresAddr  string
}

type Publisher interface {
	Publish(body []byte) error
	Close()
}

var cfg Config
var httpClient = &http.Client{Timeout: 10 * time.Second}

func loadConfig() Config {
	interval, err := time.ParseDuration(mustEnv("FETCHER_POLL_INTERVAL"))
	if err != nil || interval <= 0 {
		fatal("FETCHER_POLL_INTERVAL must be a positive Go duration (e.g. 15s)", "err", err)
	}

	c := Config{
		ISSAPIURL:    mustEnv("FETCHER_ISS_API_URL"),
		PollInterval: interval,
		QueueBackend: mustOneOf("QUEUE_BACKEND", "rabbitmq", "postgres", "pgmq"),
	}

	if c.QueueBackend != "rabbitmq" {
		c.PostgresAddr = net.JoinHostPort(mustEnv("POSTGRES_HOST"), mustEnv("POSTGRES_PORT"))
		postgresURL := url.URL{
			Scheme:   "postgres",
			User:     url.UserPassword(mustEnv("POSTGRES_FETCHER_USER"), mustEnv("POSTGRES_FETCHER_PASSWORD")),
			Host:     c.PostgresAddr,
			Path:     "/" + mustEnv("POSTGRES_DB"),
			RawQuery: "sslmode=disable",
		}
		c.PostgresURL = postgresURL.String()
		return c
	}

	c.RabbitMQAddr = net.JoinHostPort(mustEnv("RABBITMQ_HOST"), mustEnv("RABBITMQ_PORT"))
	rabbitURL := url.URL{
		Scheme: "amqp",
		User:   url.UserPassword(mustEnv("RABBITMQ_USER"), mustEnv("RABBITMQ_PASSWORD")),
		Host:   c.RabbitMQAddr,
		Path:   "/",
	}
	c.RabbitMQURL = rabbitURL.String()
	c.RabbitMQQueue = mustEnv("RABBITMQ_QUEUE")
	return c
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		fatal("missing required environment variable", "key", key)
	}
	return v
}

func mustOneOf(key string, allowed ...string) string {
	v := mustEnv(key)
	if !slices.Contains(allowed, v) {
		fatal("invalid environment variable value", "key", key, "value", v, "allowed", allowed)
	}
	return v
}

func fatal(msg string, args ...any) {
	slog.Error(msg, args...)
	os.Exit(1)
}

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, nil)))
	cfg = loadConfig()

	slog.Info("fetcher starting",
		"api", cfg.ISSAPIURL, "interval", cfg.PollInterval, "queue_backend", cfg.QueueBackend)

	for {
		publisher, err := connect()
		if err != nil {
			slog.Error("queue connect failed", "backend", cfg.QueueBackend, "err", err)
		} else {
			runPublishing(publisher)
			publisher.Close()
		}
		slog.Info("reconnecting to queue", "backend", cfg.QueueBackend, "in", 5*time.Second)
		time.Sleep(5 * time.Second)
	}
}

func connect() (Publisher, error) {
	if cfg.QueueBackend == "rabbitmq" {
		return newRabbitPublisher()
	}
	return newPostgresPublisher()
}

type rabbitPublisher struct {
	conn  *amqp.Connection
	ch    *amqp.Channel
	queue string
}

func newRabbitPublisher() (Publisher, error) {
	conn, err := amqp.Dial(cfg.RabbitMQURL)
	if err != nil {
		return nil, fmt.Errorf("rabbitmq %s: %w", cfg.RabbitMQAddr, err)
	}
	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("rabbitmq channel: %w", err)
	}
	q, err := ch.QueueDeclare(cfg.RabbitMQQueue, false, false, false, false, nil)
	if err != nil {
		ch.Close()
		conn.Close()
		return nil, fmt.Errorf("rabbitmq queue %s: %w", cfg.RabbitMQQueue, err)
	}
	slog.Info("rabbitmq connected", "addr", cfg.RabbitMQAddr, "queue", q.Name)
	return &rabbitPublisher{conn: conn, ch: ch, queue: q.Name}, nil
}

func (p *rabbitPublisher) Publish(body []byte) error {
	return p.ch.Publish("", p.queue, false, false, amqp.Publishing{
		ContentType: "application/json",
		Body:        body,
	})
}

func (p *rabbitPublisher) Close() {
	p.ch.Close()
	p.conn.Close()
}

const pgmqQueue = "positions"

type postgresPublisher struct {
	db    *sql.DB
	query string
	args  []any
}

func newPostgresPublisher() (Publisher, error) {
	db, err := sql.Open("postgres", cfg.PostgresURL)
	if err != nil {
		return nil, fmt.Errorf("postgres config: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("postgres %s: %w", cfg.PostgresAddr, err)
	}

	if cfg.QueueBackend == "pgmq" {
		slog.Info("pgmq connected", "addr", cfg.PostgresAddr, "queue", pgmqQueue)
		return &postgresPublisher{db: db, query: `SELECT pgmq.send($1, $2::jsonb)`, args: []any{pgmqQueue}}, nil
	}
	slog.Info("postgres queue connected", "addr", cfg.PostgresAddr, "table", "position_queue")
	return &postgresPublisher{db: db, query: `INSERT INTO position_queue (payload) VALUES ($1)`}, nil
}

func (p *postgresPublisher) Publish(body []byte) error {
	_, err := p.db.Exec(p.query, append(p.args, string(body))...)
	return err
}

func (p *postgresPublisher) Close() {
	p.db.Close()
}

func runPublishing(publisher Publisher) {
	for {
		resp, err := httpClient.Get(cfg.ISSAPIURL)
		if err != nil {
			slog.Warn("iss api request failed", "err", err)
			time.Sleep(cfg.PollInterval)
			continue
		}

		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			slog.Warn("iss api unexpected status", "status", resp.StatusCode)
			time.Sleep(cfg.PollInterval)
			continue
		}

		var data ISSData
		if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
			resp.Body.Close()
			slog.Warn("iss api response decode failed", "err", err)
			time.Sleep(cfg.PollInterval)
			continue
		}
		resp.Body.Close()

		body, _ := json.Marshal(data)
		if err := publisher.Publish(body); err != nil {
			slog.Error("queue publish failed", "backend", cfg.QueueBackend, "err", err)
			return
		}
		slog.Info("position published",
			"lat", data.Latitude, "lon", data.Longitude, "alt", data.Altitude, "timestamp", data.Timestamp)

		time.Sleep(cfg.PollInterval)
	}
}
