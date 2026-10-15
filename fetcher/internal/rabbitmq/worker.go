package rabbitmq

import (
	"context"
	"encoding/json"
	"errors"
	"log"

	"fetcher/internal/config"
	"fetcher/internal/syncprotocol"

	amqp "github.com/rabbitmq/amqp091-go"
)

type Worker struct {
	cfg     config.RabbitMQ
	handler syncprotocol.Handler
}

func NewWorker(cfg config.RabbitMQ, handler syncprotocol.Handler) *Worker {
	return &Worker{cfg: cfg, handler: handler}
}

func (w *Worker) Run(ctx context.Context) {
	for ctx.Err() == nil {
		session, err := Open(ctx, w.cfg, false)
		if err != nil {
			log.Printf("Fetcher RabbitMQ connection unavailable; retrying in %s", w.cfg.ReconnectInterval)
		} else {
			log.Println("Fetcher RabbitMQ connection established")
			if err := w.consume(session); err != nil && ctx.Err() == nil {
				log.Printf("Fetcher RabbitMQ consumer stopped: %v", err)
			}
			session.Close()
		}
		if !Wait(ctx, w.cfg.ReconnectInterval) {
			return
		}
	}
}

func (w *Worker) consume(session *Session) error {
	for {
		select {
		case <-session.Context.Done():
			return session.Context.Err()
		case delivery, ok := <-session.Deliveries:
			if !ok {
				return errors.New("RabbitMQ request consumer stopped")
			}
			if err := w.process(session.Context, delivery, session.Publish); err != nil {
				return err
			}
		}
	}
}

type publishFunc func(context.Context, string, amqp.Publishing) error

func (w *Worker) process(ctx context.Context, delivery amqp.Delivery, publish publishFunc) error {
	var request syncprotocol.Request
	if delivery.CorrelationId == "" || delivery.ReplyTo == "" || json.Unmarshal(delivery.Body, &request) != nil || request.Deadline.IsZero() {
		return delivery.Reject(false)
	}
	ctx, cancel := context.WithDeadline(ctx, request.Deadline)
	defer cancel()
	if ctx.Err() != nil {
		return delivery.Ack(false)
	}
	data, err := w.handler.Handle(ctx, request)
	if ctx.Err() != nil {
		return delivery.Ack(false)
	}
	response := syncprotocol.Response{Version: syncprotocol.Version, Data: data}
	if err != nil {
		response.Data = nil
		response.Error = err.Error()
	}
	body, err := json.Marshal(response)
	if err != nil {
		return delivery.Reject(false)
	}
	err = publish(ctx, delivery.ReplyTo, amqp.Publishing{
		ContentType: "application/json", CorrelationId: delivery.CorrelationId, Body: body,
	})
	if errors.Is(err, ErrUnroutable) || ctx.Err() != nil {
		return delivery.Ack(false)
	}
	if err != nil {
		return err
	}
	return delivery.Ack(false)
}
