package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"log/slog"
	"time"

	"github.com/lib/pq"
	amqp "github.com/rabbitmq/amqp091-go"
)

const queueChannel = "position_queue"
const queuePollInterval = 5 * time.Second

const (
	pgmqQueue             = "positions"
	pgmqVisibilityTimeout = 30
	pgmqBatchSize         = 10
	pgmqMaxPollSeconds    = 5
	pgmqPollIntervalMs    = 250
)

type execer interface {
	Exec(query string, args ...any) (sql.Result, error)
}

func insertPosition(e execer, data ISSData) error {
	_, err := e.Exec(`INSERT INTO positions (
			name,
			sat_id,
			latitude,
			longitude,
			altitude,
			velocity,
			visibility,
			footprint,
			timestamp,
			daynum,
			solar_lat,
			solar_lon,
			units)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)`,
		data.Name,
		data.ID,
		data.Latitude,
		data.Longitude,
		data.Altitude,
		data.Velocity,
		data.Visibility,
		data.Footprint,
		time.Unix(data.Timestamp, 0),
		data.Daynum, data.SolarLat,
		data.SolarLon,
		data.Units)
	return err
}

func consumeRabbitMQ() {
	for {
		processMessages()
		slog.Info("reconnecting to rabbitmq", "in", 5*time.Second)
		time.Sleep(5 * time.Second)
	}
}

func processMessages() {
	conn, err := amqp.Dial(cfg.RabbitMQURL)
	if err != nil {
		slog.Error("rabbitmq connect failed", "addr", cfg.RabbitMQAddr, "err", err)
		return
	}
	defer conn.Close()

	ch, err := conn.Channel()
	if err != nil {
		slog.Error("rabbitmq channel open failed", "err", err)
		return
	}
	defer ch.Close()

	q, err := ch.QueueDeclare(cfg.RabbitMQQueue, false, false, false, false, nil)
	if err != nil {
		slog.Error("rabbitmq queue declare failed", "queue", cfg.RabbitMQQueue, "err", err)
		return
	}
	msgs, err := ch.Consume(q.Name, "", true, false, false, false, nil)
	if err != nil {
		slog.Error("rabbitmq consume failed", "queue", q.Name, "err", err)
		return
	}
	slog.Info("rabbitmq consuming", "addr", cfg.RabbitMQAddr, "queue", q.Name)

	for d := range msgs {
		var data ISSData
		if err := json.Unmarshal(d.Body, &data); err != nil {
			slog.Warn("message decode failed", "err", err, "bytes", len(d.Body))
			continue
		}
		if err := insertPosition(db, data); err != nil {
			slog.Error("position insert failed", "timestamp", data.Timestamp, "err", err)
			continue
		}
		slog.Info("position stored", "lat", data.Latitude, "lon", data.Longitude, "timestamp", data.Timestamp)
	}
	slog.Warn("rabbitmq channel closed")
}

func consumePostgresQueue() {
	listener := pq.NewListener(dbURL, time.Second, time.Minute, func(event pq.ListenerEventType, err error) {
		if err != nil {
			slog.Warn("postgres listener connection event", "event", event, "err", err)
		}
	})
	if err := listener.Listen(queueChannel); err != nil {
		fatal("postgres listen failed", "channel", queueChannel, "err", err)
	}
	slog.Info("postgres queue consuming", "channel", queueChannel, "poll", queuePollInterval)

	ticker := time.NewTicker(queuePollInterval)
	defer ticker.Stop()
	for {
		drainQueue()
		select {
		case <-listener.Notify:
		case <-ticker.C:
		}
	}
}

func drainQueue() {
	for {
		processed, err := processQueuedPosition()
		if err != nil {
			slog.Error("queued position not stored, kept for retry", "err", err)
			return
		}
		if !processed {
			return
		}
	}
}

func processQueuedPosition() (bool, error) {
	tx, err := db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()

	var id int64
	var payload []byte
	err = tx.QueryRow(`DELETE FROM position_queue
		WHERE id = (SELECT id FROM position_queue ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1)
		RETURNING id, payload`).Scan(&id, &payload)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}

	var data ISSData
	if err := json.Unmarshal(payload, &data); err != nil {
		slog.Warn("queued message decode failed, dropped", "queue_id", id, "err", err)
		return true, tx.Commit()
	}
	if err := insertPosition(tx, data); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	slog.Info("position stored",
		"lat", data.Latitude, "lon", data.Longitude, "timestamp", data.Timestamp, "queue_id", id)
	return true, nil
}

type pgmqMessage struct {
	id      int64
	readCt  int
	payload []byte
}

func consumePgmq() {
	slog.Info("pgmq consuming", "queue", pgmqQueue,
		"visibility_timeout", time.Duration(pgmqVisibilityTimeout)*time.Second, "batch", pgmqBatchSize)
	for {
		msgs, err := readPgmq()
		if err != nil {
			slog.Error("pgmq read failed", "queue", pgmqQueue, "err", err)
			time.Sleep(queuePollInterval)
			continue
		}
		for _, m := range msgs {
			processPgmqMessage(m)
		}
	}
}

func readPgmq() ([]pgmqMessage, error) {
	rows, err := db.Query(`SELECT msg_id, read_ct, message
		FROM pgmq.read_with_poll($1, $2::int, $3::int, $4::int, $5::int)`,
		pgmqQueue, pgmqVisibilityTimeout, pgmqBatchSize, pgmqMaxPollSeconds, pgmqPollIntervalMs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []pgmqMessage
	for rows.Next() {
		var m pgmqMessage
		if err := rows.Scan(&m.id, &m.readCt, &m.payload); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	return msgs, rows.Err()
}

func processPgmqMessage(m pgmqMessage) {
	var data ISSData
	if err := json.Unmarshal(m.payload, &data); err != nil {
		slog.Warn("pgmq message decode failed, archived", "msg_id", m.id, "err", err)
		if _, err := db.Exec(`SELECT pgmq.archive($1, $2::bigint)`, pgmqQueue, m.id); err != nil {
			slog.Error("pgmq archive failed", "msg_id", m.id, "err", err)
		}
		return
	}

	err := func() error {
		tx, err := db.Begin()
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if err := insertPosition(tx, data); err != nil {
			return err
		}
		if _, err := tx.Exec(`SELECT pgmq.archive($1, $2::bigint)`, pgmqQueue, m.id); err != nil {
			return err
		}
		return tx.Commit()
	}()
	if err != nil {
		slog.Error("pgmq position not stored, redelivered after visibility timeout",
			"msg_id", m.id, "read_ct", m.readCt, "err", err)
		return
	}
	slog.Info("position stored",
		"lat", data.Latitude, "lon", data.Longitude, "timestamp", data.Timestamp, "msg_id", m.id, "read_ct", m.readCt)
}
