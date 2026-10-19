package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"strconv"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

type publishRequest struct {
	ctx    context.Context
	job    WeatherRequest
	result chan error
}
type Broker struct {
	url      string
	requests chan publishRequest
}

func newBroker(url string) *Broker { return &Broker{url: url, requests: make(chan publishRequest)} }

func (b *Broker) Publish(ctx context.Context, job WeatherRequest) error {
	call := publishRequest{ctx, job, make(chan error, 1)}
	select {
	case b.requests <- call:
	case <-ctx.Done():
		return ctx.Err()
	}
	select {
	case err := <-call.result:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

type brokerSession struct {
	connection *amqp.Connection
	channel    *amqp.Channel
	socket     net.Conn
	returns    <-chan amqp.Return
}

func (b *Broker) open(ctx context.Context, publisher bool) (*brokerSession, error) {
	session := &brokerSession{}
	dialCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	connection, err := amqp.DialConfig(b.url, amqp.Config{Heartbeat: 30 * time.Second,
		Dial: func(network, address string) (net.Conn, error) {
			socket, err := (&net.Dialer{Timeout: 5 * time.Second}).DialContext(dialCtx, network, address)
			if err == nil {
				session.socket = socket
				_ = socket.SetDeadline(time.Now().Add(5 * time.Second))
			}
			return socket, err
		},
	})
	if err != nil {
		return nil, fmt.Errorf("RabbitMQ connection unavailable")
	}
	session.connection = connection
	_ = session.socket.SetDeadline(time.Now().Add(5 * time.Second))
	channel, err := connection.Channel()
	if err != nil {
		_ = connection.Close()
		return nil, fmt.Errorf("RabbitMQ channel unavailable")
	}
	session.channel = channel
	for _, queue := range []string{"weather.requests", "weather.responses"} {
		if _, err = channel.QueueDeclare(queue, true, false, false, false, nil); err != nil {
			session.close()
			return nil, fmt.Errorf("RabbitMQ queue declaration failed")
		}
	}
	if publisher {
		if err = channel.Confirm(false); err != nil {
			session.close()
			return nil, err
		}
		session.returns = channel.NotifyReturn(make(chan amqp.Return, 1))
	} else if err = channel.Qos(1, 0, false); err != nil {
		session.close()
		return nil, err
	}
	_ = session.socket.SetDeadline(time.Time{})
	return session, nil
}
func (s *brokerSession) close() { _ = s.socket.Close(); _ = s.connection.Close() }

func (s *brokerSession) publish(ctx context.Context, job WeatherRequest) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	body, err := json.Marshal(job)
	if err != nil {
		return err
	}
	remaining := time.Until(job.ExpiresAt).Milliseconds()
	if remaining <= 0 {
		return fmt.Errorf("job expired before publication")
	}
	return s.confirmedPublish(ctx, "weather.requests", amqp.Publishing{
		ContentType: "application/json", DeliveryMode: amqp.Persistent, MessageId: job.RequestID,
		CorrelationId: job.RequestID, Type: job.Type, Body: body, Expiration: strconv.FormatInt(remaining, 10),
	})
}

func (s *brokerSession) confirmedPublish(ctx context.Context, key string, message amqp.Publishing) error {
	deadline, _ := ctx.Deadline()
	_ = s.socket.SetWriteDeadline(deadline)
	defer s.socket.SetWriteDeadline(time.Time{})
	confirmation, err := s.channel.PublishWithDeferredConfirmWithContext(ctx, "", key, true, false, message)
	if err != nil {
		return err
	}
	ack, err := confirmation.WaitContext(ctx)
	if err != nil || !ack {
		return fmt.Errorf("RabbitMQ did not confirm publication")
	}
	// The library dispatches basic.return before the corresponding confirm.
	select {
	case <-s.returns:
		return fmt.Errorf("RabbitMQ could not route publication")
	default:
		return nil
	}
}

// Only this goroutine owns the publisher channel. Consumer uses its own connection.
func (b *Broker) runPublisher(ctx context.Context) {
	delay := time.Second
	for ctx.Err() == nil {
		session, err := b.open(ctx, true)
		if err != nil {
			log.Print("RabbitMQ publisher disconnected")
			if !pause(ctx, delay) {
				return
			}
			delay = min(delay*2, 30*time.Second)
			continue
		}
		delay = time.Second
		healthy := true
		closed := session.connection.NotifyClose(make(chan *amqp.Error, 1))
		for healthy && ctx.Err() == nil {
			select {
			case <-ctx.Done():
				healthy = false
			case <-closed:
				healthy = false
			case call := <-b.requests:
				err := session.publish(call.ctx, call.job)
				call.result <- err
				if err != nil {
					healthy = false
				}
			}
		}
		session.close()
		if !pause(ctx, delay) {
			return
		}
	}
}

func pause(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

type responseStore interface {
	ApplyResponse(context.Context, []byte) error
}

func applyDelivery(ctx context.Context, store responseStore, delivery amqp.Delivery) error {
	var response WeatherResponse
	if len(delivery.Body) > 512*1024 || json.Unmarshal(delivery.Body, &response) != nil ||
		delivery.CorrelationId != response.RequestID || delivery.Type != response.Type {
		return delivery.Reject(false)
	}
	err := store.ApplyResponse(ctx, delivery.Body)
	if errors.Is(err, errInvalidDelivery) {
		log.Print("Rejected unrecognized weather response")
		return delivery.Reject(false)
	}
	if err != nil {
		return err
	}
	if err = delivery.Ack(false); err != nil {
		return err
	}
	log.Printf("weather response processed request_id=%s type=%s", response.RequestID, response.Type)
	return nil
}

func (b *Broker) runConsumer(ctx context.Context, store responseStore) {
	for ctx.Err() == nil {
		session, err := b.open(ctx, false)
		if err == nil {
			var deliveries <-chan amqp.Delivery
			_ = session.socket.SetDeadline(time.Now().Add(5 * time.Second))
			deliveries, err = session.channel.Consume("weather.responses", "weather-history", false, false, false, false, nil)
			_ = session.socket.SetDeadline(time.Time{})
			if err == nil {
				healthy := true
				for healthy && ctx.Err() == nil {
					select {
					case <-ctx.Done():
						healthy = false
					case delivery, ok := <-deliveries:
						if !ok {
							healthy = false
							continue
						}
						if err = applyDelivery(ctx, store, delivery); err != nil {
							healthy = false
						}
					}
				}
			}
			// Uncommitted responses return to the durable queue on connection close.
			session.close()
		}
		if ctx.Err() == nil {
			log.Print("RabbitMQ response consumer interrupted; retrying in 5 seconds")
		}
		if !pause(ctx, 5*time.Second) {
			return
		}
	}
}
