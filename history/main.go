package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/joho/godotenv"
	amqp "github.com/rabbitmq/amqp091-go"
)

// Modes of the app (app_mode in weather-vm.yml, APP_MODE in .env).
const (
	modeRabbitMQ = "rabbitmq" // queues in RabbitMQ, settings in Redis
	modePostgres = "postgres" // pgmq queues and settings in PostgreSQL
)

func main() {
	// Log timestamps are in UTC, same as in the database.
	log.SetFlags(log.LstdFlags | log.LUTC)

	// Explicitly load .env from the current folder (we run from history/).
	if err := godotenv.Load(); err != nil {
		log.Fatalf("не вдалося завантажити .env: %v (скопіюй .env.example у .env)", err)
	}

	mode := mustConfig(parseMode(os.Getenv("APP_MODE")))
	databaseURL := requireEnv("DATABASE_URL")
	fetchInterval := mustConfig(parseDuration("FETCH_INTERVAL", os.Getenv("FETCH_INTERVAL")))
	// Where History accepts connections: 127.0.0.1:8080 — this computer only,
	// 0.0.0.0:8080 — all network interfaces (needed in the VM).
	historyAddress := requireEnv("HISTORY_ADDR")

	ctx := context.Background()

	db, err := connectDB(ctx, databaseURL)
	if err != nil {
		log.Fatalf("база даних: %v", err)
	}
	defer db.Close()
	log.Printf("підключено до бази даних, режим %s", mode)

	// sendRequest makes one weather request; every mode has its own.
	var sendRequest func(context.Context)

	switch mode {
	case modeRabbitMQ:
		// amqp://user:password@host:port/vhost
		amqpURL := requireEnv("AMQP_URL")
		// redis://:password@host:port/database-number
		redisURL := requireEnv("REDIS_URL")

		cache, err := connectCache(ctx, redisURL)
		if err != nil {
			log.Fatalf("Redis: %v", err)
		}
		defer cache.Close()
		startHTTP(historyAddress, db, redisSettings{client: cache})

		queue, err := connectQueue(amqpURL)
		if err != nil {
			log.Fatalf("RabbitMQ: %v", err)
		}
		defer queue.Close()
		log.Println("підключено до RabbitMQ")

		// Responses are read separately, all the time, in their own goroutine
		// (a function that runs in parallel with the rest of the program).
		go func() {
			err := consumeResponses(ctx, queue, func(ctx context.Context, record WeatherRecord) (bool, error) {
				return saveRecord(ctx, db, record)
			})
			// Without RabbitMQ History cannot work: exit, and Docker restarts it.
			log.Fatalf("відповіді з RabbitMQ: %v", err)
		}()

		publishChannel, err := newPublishChannel(queue)
		if err != nil {
			log.Fatalf("RabbitMQ: %v", err)
		}
		defer publishChannel.Close()
		sendRequest = func(ctx context.Context) { sendRabbitMQRequest(ctx, publishChannel) }

	case modePostgres:
		// How often to look into the queue weather_responses when it is empty (only a query).
		pollInterval := mustConfig(parseDuration("QUEUE_POLL_INTERVAL", os.Getenv("QUEUE_POLL_INTERVAL")))
		startHTTP(historyAddress, db, pgSettings{db: db})
		go consumePGResponses(ctx, db, pollInterval)
		// Old settings are removed by the pg_cron job weather-expired-settings in PostgreSQL
		// (like the TTL of Redis), not by History.
		sendRequest = func(ctx context.Context) { sendPGRequest(ctx, db) }
	}

	requestsStopped := stopRequestsOnSignal()

	// First request — right at startup. Then — every fetchInterval (5 minutes).
	sendRequest(ctx)
	ticker := time.NewTicker(fetchInterval)
	defer ticker.Stop()
	log.Printf("наступні запити — кожні %s", fetchInterval)

	for range ticker.C {
		if requestsStopped.Load() {
			continue
		}
		sendRequest(ctx)
	}
}

// startHTTP starts the API and the UI in their own goroutine.
func startHTTP(address string, db *pgxpool.Pool, settings settingsStore) {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/history", historyHandler(func(ctx context.Context) ([]WeatherRecord, error) {
		return latestRecords(ctx, db)
	}))
	mux.HandleFunc("/api/settings", settingsHandler(settings))
	mux.Handle("/", uiHandler())
	go func() {
		log.Printf("HTTP API слухає http://%s", address)
		if err := http.ListenAndServe(address, mux); err != nil {
			log.Fatalf("HTTP API: %v", err)
		}
	}()
}

// stopRequestsOnSignal: after the signal USR1 History makes no new requests, but keeps
// handling the responses and serving HTTP. scripts/switch-mode.sh sends it before a switch
// (docker kill --signal USR1), so the old queue can be emptied. Only a restart
// of the container makes requests again.
func stopRequestsOnSignal() *atomic.Bool {
	var stopped atomic.Bool
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGUSR1)
	go func() {
		for range signals {
			if !stopped.Swap(true) {
				log.Println("отримано USR1: нові запити зупинено; відповіді й HTTP працюють далі")
			}
		}
	}()
	return &stopped
}

// sendRabbitMQRequest puts one weather request into the queue. The answer comes later
// to consumeResponses. An error does not stop the program: we log it and wait for the next run.
func sendRabbitMQRequest(ctx context.Context, ch *amqp.Channel) {
	requestID, err := publishRequest(ctx, ch)
	if errors.Is(err, amqp.ErrClosed) {
		// The channel is closed and will not open by itself: exit, Docker restarts History.
		log.Fatalf("ПОМИЛКА надсилання запиту: %v", err)
	}
	if err != nil {
		log.Printf("ПОМИЛКА надсилання запиту: %v", err)
		return
	}
	log.Printf("запит %s надіслано в чергу %s", requestID, requestsQueue)
}

// sendPGRequest puts one weather request into the pgmq queue weather_requests.
// An error does not stop the program: we log it and wait for the next run.
func sendPGRequest(ctx context.Context, db *pgxpool.Pool) {
	requestID, err := publishPGRequest(ctx, db)
	if err != nil {
		log.Printf("ПОМИЛКА надсилання запиту: %v", err)
		return
	}
	log.Printf("запит %s надіслано в чергу pgmq %s", requestID, pgRequestsQueue)
}

// historyHandler returns the latest records as JSON.
func historyHandler(getRecords func(context.Context) ([]WeatherRecord, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", http.MethodGet)
			http.Error(w, "підтримується лише GET", http.StatusMethodNotAllowed)
			return
		}

		records, err := getRecords(r.Context())
		if err != nil {
			log.Printf("ПОМИЛКА читання історії: %v", err)
			http.Error(w, "не вдалося прочитати історію погоди", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		if err := json.NewEncoder(w).Encode(records); err != nil {
			log.Printf("ПОМИЛКА відповіді API історії: %v", err)
		}
	}
}

// uiHandler serves the UI files (index.html, app.js, style.css) from ../ui.
// Cache-Control: no-cache — the browser asks every time whether a file has changed
// (if not, the answer is a short 304). Without it a phone may keep an old app.js
// after an update.
func uiHandler() http.Handler {
	files := http.FileServer(http.Dir("../ui"))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		files.ServeHTTP(w, r)
	})
}

// requireEnv returns an environment variable or stops the program with a clear error.
func requireEnv(name string) string {
	value := os.Getenv(name)
	if value == "" {
		log.Fatalf("змінна %s не задана. Скопіюй .env.example у .env", name)
	}
	return value
}

// mustConfig stops the program with a clear error if a setting is wrong.
func mustConfig[T any](value T, err error) T {
	if err != nil {
		log.Fatal(err)
	}
	return value
}

// parseMode checks APP_MODE: only rabbitmq or postgres.
func parseMode(value string) (string, error) {
	if value == modeRabbitMQ || value == modePostgres {
		return value, nil
	}
	return "", fmt.Errorf("змінна APP_MODE=%q: потрібно %s або %s (app_mode у weather-vm.yml)",
		value, modeRabbitMQ, modePostgres)
}

// parseDuration reads a duration such as "5s" or "5m"; it must be more than zero.
func parseDuration(name, value string) (time.Duration, error) {
	if value == "" {
		return 0, fmt.Errorf("змінна %s не задана: потрібна тривалість, наприклад 5s або 5m", name)
	}
	duration, err := time.ParseDuration(value)
	if err != nil || duration <= 0 {
		return 0, fmt.Errorf("змінна %s=%q: потрібна тривалість більша за нуль, наприклад 5s або 5m",
			name, value)
	}
	return duration, nil
}
