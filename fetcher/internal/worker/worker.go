// Package worker is the Fetcher's only interface: it consumes fetch requests from a RabbitMQ
// queue, calls Open-Meteo and publishes the reply to the queue named in the request's ReplyTo,
// with the same CorrelationId (request/reply over AMQP).
package worker

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

// Queue names shared with the History service.
const (
	RequestQueue = "weather.fetch.requests"
	ReplyQueue   = "weather.fetch.replies"
)

const (
	prefetch     = 4                // requests processed in parallel
	fetchTimeout = 15 * time.Second // per request, Open-Meteo call included
)

// Run consumes requests until ctx is cancelled (returns nil) or the connection to RabbitMQ
// is lost (returns an error). It does not reconnect: the process exits and Docker restarts it.
func Run(ctx context.Context, url string, w Weather) error {
	conn, err := amqp.Dial(url)
	if err != nil {
		return fmt.Errorf("connect to RabbitMQ: %w", err)
	}
	defer conn.Close()

	ch, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("open channel: %w", err)
	}
	// Both sides declare both queues with the same arguments, so start-up order does not matter
	for _, q := range []string{RequestQueue, ReplyQueue} {
		if _, err := ch.QueueDeclare(q, true, false, false, false, nil); err != nil {
			return fmt.Errorf("declare queue %s: %w", q, err)
		}
	}
	if err := ch.Qos(prefetch, 0, false); err != nil {
		return fmt.Errorf("set prefetch: %w", err)
	}
	deliveries, err := ch.Consume(RequestQueue, "", false, false, false, false, nil)
	if err != nil {
		return fmt.Errorf("consume %s: %w", RequestQueue, err)
	}
	closed := conn.NotifyClose(make(chan *amqp.Error, 1))
	slog.Info("Fetcher worker consuming", "queue", RequestQueue)

	// In-flight requests finish (and get acked) before the connection is closed
	var wg sync.WaitGroup
	defer wg.Wait()

	for {
		select {
		case <-ctx.Done():
			slog.Info("shutting down")
			return nil
		case amqpErr := <-closed:
			return fmt.Errorf("RabbitMQ connection lost: %v", amqpErr)
		case d, ok := <-deliveries:
			if !ok {
				return errors.New("RabbitMQ stopped delivering requests")
			}
			wg.Add(1)
			go func() {
				defer wg.Done()
				respond(ch, w, d)
			}()
		}
	}
}

// respond handles one delivery. The request is acked only after the reply is published, so a
// crash in between makes RabbitMQ redeliver it.
func respond(ch *amqp.Channel, w Weather, d amqp.Delivery) {
	ctx, cancel := context.WithTimeout(context.Background(), fetchTimeout)
	defer cancel()

	if d.ReplyTo == "" {
		slog.Warn("dropping request without ReplyTo", "correlationId", d.CorrelationId)
		_ = d.Ack(false)
		return
	}
	body, err := json.Marshal(Handle(ctx, w, d.Body))
	if err != nil {
		slog.Error("cannot encode reply", "error", err)
		body = []byte(`{"ok":false,"error":"Internal error","kind":"internal"}`)
	}
	err = ch.PublishWithContext(ctx, "", d.ReplyTo, false, false, amqp.Publishing{
		ContentType:   "application/json",
		CorrelationId: d.CorrelationId,
		DeliveryMode:  amqp.Persistent,
		Body:          body,
	})
	if err != nil {
		slog.Error("cannot publish reply", "error", err, "correlationId", d.CorrelationId)
		_ = d.Nack(false, true)
		return
	}
	_ = d.Ack(false)
}
