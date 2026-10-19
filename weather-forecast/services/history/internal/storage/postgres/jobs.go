package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"weather-history/internal/config"
	"weather-history/internal/domain"
)

const jobColumns = "request_id::text, type, status, request_payload, created_at, expires_at, processed_at, error, result"

const expireSQL = `UPDATE weather_jobs SET status='failed', processed_at=NOW(),
 error='{"code":"job_expired","message":"Job deadline expired"}'::jsonb
 WHERE status='queued' AND expires_at <= NOW()`

func scanJob(row pgx.Row) (domain.Job, error) {
	var job domain.Job
	var payload, failure []byte
	err := row.Scan(&job.RequestID, &job.Type, &job.Status, &payload, &job.CreatedAt,
		&job.ExpiresAt, &job.ProcessedAt, &failure, &job.Result)
	if err != nil {
		return job, err
	}
	if err = json.Unmarshal(payload, &job.Request); err != nil {
		return job, err
	}
	if len(failure) > 0 {
		err = json.Unmarshal(failure, &job.Error)
	}
	job.CreatedAt, job.ExpiresAt = job.CreatedAt.UTC(), job.ExpiresAt.UTC()
	if job.ProcessedAt != nil {
		utc := job.ProcessedAt.UTC()
		job.ProcessedAt = &utc
	}
	return job, err
}

func (s *Store) CreateJob(ctx context.Context, request domain.WeatherRequest) (domain.Job, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return domain.Job{}, err
	}
	defer tx.Rollback(ctx)
	// Serialize job creation for this type, even across a History restart.
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtext($1))", request.Type); err != nil {
		return domain.Job{}, err
	}
	if _, err = tx.Exec(ctx, expireSQL); err != nil {
		return domain.Job{}, err
	}
	active, err := scanJob(tx.QueryRow(ctx, "SELECT "+jobColumns+" FROM weather_jobs WHERE type=$1 AND status='queued'", request.Type))
	if err == nil {
		if err := tx.Commit(ctx); err != nil {
			return domain.Job{}, err
		}
		return active, &domain.APIError{Status: http.StatusConflict, Message: domain.ErrBusy.Message, RequestID: active.RequestID}
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return domain.Job{}, err
	}
	payload, err := json.Marshal(request)
	if err != nil {
		return domain.Job{}, err
	}
	job, err := scanJob(tx.QueryRow(ctx, `INSERT INTO weather_jobs
 (request_id,type,status,request_payload,expires_at,backend) VALUES ($1,$2,'queued',$3,$4,$5) RETURNING `+jobColumns,
		request.RequestID, request.Type, payload, request.ExpiresAt, s.queueBackend()))
	if err != nil {
		return domain.Job{}, err
	}
	if s.queueBackend() == config.BackendPostgres {
		if _, err = tx.Exec(ctx, "SELECT pgmq.send('weather_requests', $1::jsonb)", payload); err != nil {
			return domain.Job{}, err
		}
		if _, err = tx.Exec(ctx, "UPDATE weather_jobs SET published_at=NOW() WHERE request_id=$1", request.RequestID); err != nil {
			return domain.Job{}, err
		}
	}
	return job, tx.Commit(ctx)
}

func (s *Store) ExpireJobs(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_, err := s.pool.Exec(ctx, expireSQL)
	if err == nil && s.queueBackend() == config.BackendPostgres {
		_, err = s.pool.Exec(ctx, `DELETE FROM pgmq.q_weather_requests q
 USING weather_jobs j WHERE q.message->>'request_id'=j.request_id::text AND j.expires_at<=NOW()`)
		if err == nil {
			_, err = s.pool.Exec(ctx, `DELETE FROM pgmq.q_weather_responses q
 USING weather_jobs j WHERE q.message->>'request_id'=j.request_id::text AND j.expires_at<=NOW()`)
		}
	}
	return err
}

func (s *Store) GetJob(ctx context.Context, id string) (domain.Job, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := s.ExpireJobs(ctx); err != nil {
		return domain.Job{}, err
	}
	return scanJob(s.pool.QueryRow(ctx, "SELECT "+jobColumns+" FROM weather_jobs WHERE request_id=$1", id))
}

func (s *Store) UnpublishedJobs(ctx context.Context) ([]domain.WeatherRequest, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx, "SELECT request_payload FROM weather_jobs WHERE backend='rabbitmq_redis' AND status='queued' AND published_at IS NULL AND expires_at>NOW() ORDER BY created_at")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var requests []domain.WeatherRequest
	for rows.Next() {
		var body []byte
		if err := rows.Scan(&body); err != nil {
			return nil, err
		}
		var request domain.WeatherRequest
		if err := json.Unmarshal(body, &request); err != nil {
			return nil, err
		}
		requests = append(requests, request)
	}
	return requests, rows.Err()
}

func (s *Store) MarkPublished(ctx context.Context, id string) error {
	_, err := s.pool.Exec(ctx, "UPDATE weather_jobs SET published_at=COALESCE(published_at,NOW()) WHERE request_id=$1", id)
	return err
}

// Returning nil transfers ownership: the caller can now acknowledge the message.
func (s *Store) ApplyResponse(ctx context.Context, body []byte) error {
	var response domain.WeatherResponse
	if len(body) > 512*1024 || json.Unmarshal(body, &response) != nil || !domain.UUIDPattern.MatchString(response.RequestID) {
		return domain.ErrInvalidDelivery
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err := s.applyResponseTx(ctx, tx, response); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *Store) applyResponseTx(ctx context.Context, tx pgx.Tx, response domain.WeatherResponse) error {
	job, err := scanJob(tx.QueryRow(ctx, "SELECT "+jobColumns+" FROM weather_jobs WHERE request_id=$1 AND backend=$2 FOR UPDATE", response.RequestID, s.queueBackend()))
	if errors.Is(err, pgx.ErrNoRows) {
		return domain.ErrInvalidDelivery
	}
	if err != nil {
		return err
	}
	if job.Status != "queued" {
		return nil
	}
	weather, points, failure := domain.ValidateResponse(job.Request, response)
	if !time.Now().UTC().Before(job.ExpiresAt) {
		failure = &domain.JobFailure{"job_expired", "Job deadline expired"}
	}
	status := "completed"
	var result any
	if failure != nil {
		status = "failed"
	} else if job.Type == domain.CurrentWeather {
		snapshot, err := insertSnapshot(ctx, tx, domain.Snapshot{Weather: weather, FetchedAt: time.Now().UTC()})
		if err != nil {
			return err
		}
		result = map[string]int64{"snapshot_id": snapshot.ID}
	} else {
		if err := saveTemperature(ctx, tx, job.Request.City, points); err != nil {
			return err
		}
		result = map[string]int{"points_count": len(points)}
	}
	resultJSON, _ := json.Marshal(result)
	errorJSON, _ := json.Marshal(failure)
	_, err = tx.Exec(ctx, `UPDATE weather_jobs SET status=$2, processed_at=NOW(), error=$3, result=$4 WHERE request_id=$1`,
		job.RequestID, status, errorJSON, resultJSON)
	return err
}
