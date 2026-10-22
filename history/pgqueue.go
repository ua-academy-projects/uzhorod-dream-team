package main

// The queue in PostgreSQL (app_mode postgres): the queues weather_requests and weather_responses
// of the extension pgmq instead of the RabbitMQ queues. The messages are the same JSON
// (see messages.go). The queues are created by provision/db-mode.sh.

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Names of the pgmq queues: like weather.requests and weather.responses in RabbitMQ.
const (
	pgRequestsQueue  = "weather_requests"
	pgResponsesQueue = "weather_responses"
)

// A request older than this is not needed: a new one is made every FETCH_INTERVAL (5 minutes).
// The same as x-message-ttl of weather.requests in RabbitMQ.
const requestTTL = 5 * time.Minute

// How long a response taken by pgmq.read is hidden from other readers (visibility timeout).
// It is taken and removed in one transaction, so this matters only while it is being saved.
const responseVisibilitySeconds = 30

// publishPGRequest puts a new request into the queue weather_requests (pgmq.send).
// Old requests are removed first (see deleteStaleRequests).
func publishPGRequest(ctx context.Context, db *pgxpool.Pool) (string, error) {
	if removed, err := deleteStaleRequests(ctx, db); err != nil {
		log.Printf("ПОМИЛКА видалення старих запитів: %v", err)
	} else if removed > 0 {
		log.Printf("видалено %d старих запитів (старші за %s, ніхто їх не обробляє)", removed, requestTTL)
	}

	// A random id, so that the request can be found in the logs of both services.
	requestID := rand.Text()
	body, err := newRequest(requestID, time.Now().UTC())
	if err != nil {
		return "", fmt.Errorf("запит у JSON: %w", err)
	}
	if _, err := db.Exec(ctx, `SELECT pgmq.send($1, $2::jsonb)`, pgRequestsQueue, string(body)); err != nil {
		return "", fmt.Errorf("pgmq.send у %s: %w", pgRequestsQueue, err)
	}
	return requestID, nil
}

// deleteStaleRequests removes requests older than requestTTL that are waiting: Fetcher
// does not work, and pgmq has no TTL of its own (RabbitMQ has x-message-ttl).
// A request that Fetcher has taken (vt in the future) is not removed: it is being handled.
// SKIP LOCKED: a row that Fetcher is taking at this moment is skipped, not waited for.
// The rows are only chosen here; pgmq.delete removes them.
func deleteStaleRequests(ctx context.Context, db *pgxpool.Pool) (int64, error) {
	var removed int64
	err := db.QueryRow(ctx, `
		SELECT count(*) FROM pgmq.delete($1, ARRAY(
			SELECT msg_id FROM pgmq.q_weather_requests
			WHERE enqueued_at < now() - make_interval(secs => $2)
			  AND vt <= now()
			FOR UPDATE SKIP LOCKED))`,
		pgRequestsQueue, requestTTL.Seconds(),
	).Scan(&removed)
	return removed, err
}

// consumePGResponses handles the queue weather_responses all the time. When it is empty,
// it waits pollInterval and looks again: this is only a query to the queue, Open-Meteo
// is asked by Fetcher only for a request. When there was a response, the next one is
// taken at once.
func consumePGResponses(ctx context.Context, db *pgxpool.Pool, pollInterval time.Duration) {
	log.Printf("читаю відповіді з черги pgmq %s (перевірка кожні %s)", pgResponsesQueue, pollInterval)
	for {
		found, err := handleOnePGResponse(ctx, db)
		switch {
		case err != nil:
			// The response stays in the queue (rollback) and is handled again after a pause.
			log.Printf("ПОМИЛКА обробки відповіді: %v — спробуємо ще раз через %s", err, retryDelay)
			time.Sleep(retryDelay)
		case !found:
			time.Sleep(pollInterval)
		}
	}
}

// errRetryResponse: the response was not saved (for example, the database failed);
// it must stay in the queue for the next attempt.
var errRetryResponse = errors.New("відповідь не збережено")

// handleOnePGResponse takes the oldest response and handles it in ONE transaction:
// pgmq.read -> save the weather -> pgmq.delete -> COMMIT.
// If anything fails, the transaction is rolled back and the response stays in the queue
// (the rollback also undoes what pgmq.read changed, so it can be read again at once).
// It returns found=false if there was no response to handle.
func handleOnePGResponse(ctx context.Context, db *pgxpool.Pool) (bool, error) {
	tx, err := db.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("початок транзакції: %w", err)
	}
	// After Commit this does nothing; on any early return it rolls back.
	defer tx.Rollback(ctx)

	// pgmq.read locks the message (FOR UPDATE SKIP LOCKED inside) and hides it from
	// other readers; one message at a time.
	var msgID int64
	var body string
	err = tx.QueryRow(ctx, `SELECT msg_id, message::text FROM pgmq.read($1, $2, 1)`,
		pgResponsesQueue, responseVisibilitySeconds).Scan(&msgID, &body)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("pgmq.read з %s: %w", pgResponsesQueue, err)
	}

	// The weather is saved through the same transaction, so it is saved
	// only together with the removal of the response.
	action := handleResponse(ctx, []byte(body), func(ctx context.Context, record WeatherRecord) (bool, error) {
		return saveRecord(ctx, tx, record)
	})
	if action == retryResponse {
		return true, errRetryResponse
	}

	// ackResponse (saved, a duplicate, or an error of Fetcher logged) and rejectResponse
	// (a broken message): the response is done and is removed.
	if _, err := tx.Exec(ctx, `SELECT pgmq.delete($1, $2::bigint)`, pgResponsesQueue, msgID); err != nil {
		return true, fmt.Errorf("pgmq.delete з %s: %w", pgResponsesQueue, err)
	}
	if err := tx.Commit(ctx); err != nil {
		return true, fmt.Errorf("COMMIT: %w", err)
	}
	return true, nil
}
