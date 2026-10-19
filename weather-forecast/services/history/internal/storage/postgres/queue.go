package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"time"

	"github.com/jackc/pgx/v5"

	"weather-history/internal/domain"
	"weather-history/internal/retry"
)

// A response is locked, applied, and acknowledged in one short transaction.
func (s *Store) consumePostgresResponse(ctx context.Context) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	var messageID int64
	var body []byte
	err = tx.QueryRow(ctx, "SELECT msg_id, message FROM pgmq.read('weather_responses', 30, 1)").Scan(&messageID, &body)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var response domain.WeatherResponse
	if len(body) > 512*1024 || json.Unmarshal(body, &response) != nil || !domain.UUIDPattern.MatchString(response.RequestID) {
		err = domain.ErrInvalidDelivery
	} else {
		err = s.applyResponseTx(ctx, tx, response)
	}
	if err != nil && !errors.Is(err, domain.ErrInvalidDelivery) {
		return false, err
	}
	rejected := errors.Is(err, domain.ErrInvalidDelivery)
	if _, err = tx.Exec(ctx, "SELECT pgmq.delete('weather_responses', $1::bigint)", messageID); err != nil {
		return false, err
	}
	if err = tx.Commit(ctx); err != nil {
		return false, err
	}
	if rejected {
		log.Printf("Rejected PGMQ weather response msg_id=%d", messageID)
	} else {
		log.Printf("weather response processed request_id=%s type=%s backend=postgres", response.RequestID, response.Type)
	}
	return true, nil
}

func (s *Store) RunConsumer(ctx context.Context) {
	delay := time.Second
	for ctx.Err() == nil {
		consumed, err := s.consumePostgresResponse(ctx)
		if err != nil {
			if ctx.Err() == nil {
				log.Printf("PostgreSQL response consumer interrupted; retrying in %s", delay)
			}
			if !retry.Pause(ctx, delay) {
				return
			}
			delay = min(delay*2, 30*time.Second)
			continue
		}
		delay = time.Second
		if !consumed && !retry.Pause(ctx, time.Second) {
			return
		}
	}
}
