package rabbitmq

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strconv"
	"sync"
	"time"

	"history/internal/config"
	"history/internal/syncprotocol"

	amqp "github.com/rabbitmq/amqp091-go"
)

type Client struct {
	cfg     config.RabbitMQ
	ctx     context.Context
	cancel  context.CancelFunc
	done    chan struct{}
	gate    chan struct{}
	mu      sync.Mutex
	session *Session
	changed chan struct{}
}

func NewClient(ctx context.Context, cfg config.RabbitMQ) *Client {
	ctx, cancel := context.WithCancel(ctx)
	c := &Client{cfg: cfg, ctx: ctx, cancel: cancel, done: make(chan struct{}), gate: make(chan struct{}, 1), changed: make(chan struct{})}
	c.gate <- struct{}{}
	go c.run()
	return c
}

func (c *Client) Close() {
	c.cancel()
	<-c.done
}

func (c *Client) run() {
	defer close(c.done)
	for c.ctx.Err() == nil {
		session, err := Open(c.ctx, c.cfg, true)
		if err != nil {
			log.Printf("History RabbitMQ connection unavailable; retrying in %s", c.cfg.ReconnectInterval)
		} else {
			c.setSession(session)
			log.Println("History RabbitMQ connection established")
			<-session.Context.Done()
			c.setSession(nil)
			session.Close()
		}
		if !Wait(c.ctx, c.cfg.ReconnectInterval) {
			return
		}
	}
}

func (c *Client) setSession(s *Session) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.session = s
	close(c.changed)
	c.changed = make(chan struct{})
}

func (c *Client) getSession(ctx context.Context) (*Session, error) {
	for {
		c.mu.Lock()
		session, changed := c.session, c.changed
		c.mu.Unlock()
		if session != nil && session.Context.Err() == nil {
			return session, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-c.ctx.Done():
			return nil, errors.New("RabbitMQ client stopped")
		case <-changed:
		}
	}
}

func (c *Client) Call(ctx context.Context, request syncprotocol.Request) (json.RawMessage, error) {
	if _, ok := ctx.Deadline(); !ok {
		return nil, errors.New("RabbitMQ request requires a deadline")
	}
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-c.ctx.Done():
		return nil, errors.New("RabbitMQ client stopped")
	case <-c.gate:
	}
	defer func() { c.gate <- struct{}{} }()
	session, err := c.getSession(ctx)
	if err != nil {
		return nil, err
	}
	request.Version = syncprotocol.Version
	request.Deadline, _ = ctx.Deadline()
	body, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	remaining := time.Until(request.Deadline)
	if remaining <= 0 {
		return nil, context.DeadlineExceeded
	}
	correlationID := rand.Text()
	if err := session.Publish(ctx, c.cfg.RequestQueue, amqp.Publishing{
		ContentType: "application/json", DeliveryMode: amqp.Persistent,
		CorrelationId: correlationID, ReplyTo: session.ReplyQueue,
		Expiration: strconv.FormatInt(max(1, remaining.Milliseconds()), 10), Body: body,
	}); err != nil {
		return nil, fmt.Errorf("publish Fetcher request: %w", err)
	}
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-session.Context.Done():
			return nil, errors.New("RabbitMQ connection interrupted")
		case delivery, ok := <-session.Deliveries:
			if !ok {
				return nil, errors.New("RabbitMQ reply consumer stopped")
			}
			if err := delivery.Ack(false); err != nil {
				return nil, err
			}
			if delivery.CorrelationId != correlationID {
				continue
			}
			var response syncprotocol.Response
			if err := json.Unmarshal(delivery.Body, &response); err != nil {
				return nil, fmt.Errorf("decode Fetcher reply: %w", err)
			}
			if response.Version != syncprotocol.Version {
				return nil, errors.New("unsupported Fetcher reply version")
			}
			if response.Error != "" {
				return nil, fmt.Errorf("Fetcher: %s", response.Error)
			}
			if len(response.Data) == 0 {
				return nil, errors.New("Fetcher reply contains no data")
			}
			return response.Data, nil
		}
	}
}
