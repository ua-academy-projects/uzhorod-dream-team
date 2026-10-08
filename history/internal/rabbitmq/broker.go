package rabbitmq

import (
	"context"
	"errors"
	"fmt"
	"net"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
	"history/internal/config"
)

var ErrUnroutable = errors.New("RabbitMQ destination is unavailable")

type Session struct {
	Context      context.Context
	Deliveries   <-chan amqp.Delivery
	ReplyQueue   string
	conn         *amqp.Connection
	consumer     *amqp.Channel
	publisher    *amqp.Channel
	returned     <-chan amqp.Return
	cancel       context.CancelFunc
	closeTimeout time.Duration
}

func Open(ctx context.Context, cfg config.RabbitMQ, reply bool) (*Session, error) {
	conn, err := amqp.DialConfig(cfg.URL, amqp.Config{
		Heartbeat:  5 * time.Second,
		Properties: amqp.Table{"connection_name": cfg.RequestQueue + "/history"},
		Dial: func(network, address string) (net.Conn, error) {
			socket, err := (&net.Dialer{Timeout: cfg.ConnectionTimeout}).DialContext(ctx, network, address)
			if err != nil {
				return nil, err
			}
			if err := socket.SetDeadline(time.Now().Add(cfg.ConnectionTimeout)); err != nil {
				socket.Close()
				return nil, err
			}
			return socket, nil
		},
	})
	if err != nil {
		return nil, errors.New("RabbitMQ connection failed")
	}
	sessionCtx, cancel := context.WithCancel(ctx)
	s := &Session{Context: sessionCtx, conn: conn, cancel: cancel, closeTimeout: cfg.ConnectionTimeout}
	stop := context.AfterFunc(sessionCtx, func() { conn.CloseDeadline(time.Now().Add(cfg.ConnectionTimeout)) })
	success := false
	defer func() {
		if !success {
			s.Close()
			stop()
		}
	}()
	s.consumer, err = conn.Channel()
	if err != nil {
		return nil, err
	}
	s.publisher, err = conn.Channel()
	if err != nil {
		return nil, err
	}
	if err := s.publisher.Confirm(false); err != nil {
		return nil, err
	}
	s.returned = s.publisher.NotifyReturn(make(chan amqp.Return, 1))
	if _, err := s.consumer.QueueDeclare(cfg.RequestQueue, true, false, false, false, nil); err != nil {
		return nil, err
	}
	queue := cfg.RequestQueue
	if reply {
		callback, err := s.consumer.QueueDeclare("", false, true, true, false, nil)
		if err != nil {
			return nil, err
		}
		queue = callback.Name
		s.ReplyQueue = queue
	}
	if err := s.consumer.Qos(1, 0, false); err != nil {
		return nil, err
	}
	s.Deliveries, err = s.consumer.Consume(queue, "", false, reply, false, false, nil)
	if err != nil {
		return nil, err
	}
	connectionClosed := conn.NotifyClose(make(chan *amqp.Error, 1))
	consumerClosed := s.consumer.NotifyClose(make(chan *amqp.Error, 1))
	publisherClosed := s.publisher.NotifyClose(make(chan *amqp.Error, 1))
	consumerCancelled := s.consumer.NotifyCancel(make(chan string, 1))
	go func() {
		select {
		case <-sessionCtx.Done():
		case <-connectionClosed:
		case <-consumerClosed:
		case <-publisherClosed:
		case <-consumerCancelled:
		}
		s.cancel()
	}()
	success = true
	return s, nil
}

func (s *Session) Close() {
	s.cancel()
	s.conn.CloseDeadline(time.Now().Add(s.closeTimeout))
}

func (s *Session) Publish(ctx context.Context, queue string, message amqp.Publishing) error {
	publishCtx, cancel := context.WithCancel(ctx)
	stopSession := context.AfterFunc(s.Context, cancel)
	stopPublish := context.AfterFunc(publishCtx, s.Close)
	defer func() { stopPublish(); stopSession(); cancel() }()
	confirmation, err := s.publisher.PublishWithDeferredConfirmWithContext(publishCtx, "", queue, true, false, message)
	if err != nil {
		return err
	}
	acked, err := confirmation.WaitContext(publishCtx)
	if err != nil {
		s.Close()
		return err
	}
	if !acked {
		return errors.New("RabbitMQ rejected publication")
	}
	select {
	case returned := <-s.returned:
		return fmt.Errorf("%w: %s", ErrUnroutable, returned.ReplyText)
	default:
		return nil
	}
}

func Wait(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
