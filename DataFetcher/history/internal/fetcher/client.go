package fetcher

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/rabbitmq/amqp091-go"

	"data-monitor/history/internal/models"
)

const RequestQueue = "fetcher.requests"

type Client struct{ Channel *amqp091.Channel }
type request struct {
	Type string `json:"type"`
}
type response struct {
	Data  []models.Current `json:"data"`
	Error string           `json:"error,omitempty"`
}

// All sends an asynchronous fetch request and waits for its correlated reply.
func (c Client) All(ctx context.Context) ([]models.Current, error) {
	if c.Channel == nil {
		return nil, errors.New("RabbitMQ channel is not configured")
	}
	q, err := c.Channel.QueueDeclare("", false, true, true, false, nil)
	if err != nil {
		return nil, err
	}
	defer func() {
    _, _ = c.Channel.QueueDelete(q.Name, false, false, false)}()
	replies, err := c.Channel.Consume(q.Name, "", true, true, false, false, nil)
	if err != nil {
		return nil, err
	}
	corrID := time.Now().UTC().Format("20060102150405.000000000")
	body, _ := json.Marshal(request{Type: "fetch_all"})
	err = c.Channel.PublishWithContext(ctx, "", RequestQueue, false, false, amqp091.Publishing{ContentType: "application/json", CorrelationId: corrID, ReplyTo: q.Name, Body: body})
	if err != nil {
		return nil, err
	}
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case msg, ok := <-replies:
		if !ok {
			return nil, errors.New("RabbitMQ reply channel closed")
		}
		if msg.CorrelationId != corrID {
			return nil, errors.New("unexpected RabbitMQ correlation id")
		}
		var result response
		if err := json.Unmarshal(msg.Body, &result); err != nil {
			return nil, err
		}
		if result.Error != "" {
			return nil, errors.New(result.Error)
		}
		valid := make([]models.Current, 0, len(result.Data))
		for _, item := range result.Data {
			if item.Source == "" || item.Value <= 0 {
				continue
			}
			if item.Timestamp.IsZero() {
				item.Timestamp = time.Now().UTC()
			}
			valid = append(valid, item)
		}
		if len(valid) == 0 {
			return nil, errors.New("fetcher returned no valid items")
		}
		return valid, nil
	}
}
