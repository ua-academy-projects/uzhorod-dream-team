package main

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

// Both services declare the queues with exactly the same settings
// (see fetcher/messages.py), otherwise RabbitMQ refuses the connection.
const (
	requestsQueue  = "weather.requests"
	responsesQueue = "weather.responses"

	// How long to wait until RabbitMQ confirms that it stored a request.
	publishTimeout = 10 * time.Second
	// Pause before a response is returned to the queue after a database error.
	retryDelay = 5 * time.Second
)

func queueArguments() amqp.Table {
	return amqp.Table{
		// Quorum queue: stored on disk and counts how many times a message was delivered.
		"x-queue-type": "quorum",
		// After 5 failed deliveries the message is removed, so it does not repeat forever.
		"x-delivery-limit": 5,
	}
}

func requestsQueueArguments() amqp.Table {
	arguments := queueArguments()
	// A request older than 5 minutes is not needed: a new one is sent every 5 minutes.
	arguments["x-message-ttl"] = 5 * 60 * 1000 // milliseconds
	return arguments
}

// connectQueue connects to RabbitMQ and creates both queues if they do not exist yet.
func connectQueue(amqpURL string) (*amqp.Connection, error) {
	conn, err := amqp.Dial(amqpURL)
	if err != nil {
		return nil, fmt.Errorf("не вдалося підключитися до RabbitMQ: %w", err)
	}

	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("канал RabbitMQ: %w", err)
	}
	defer ch.Close()

	// durable: the queue survives a RabbitMQ restart.
	if _, err := ch.QueueDeclare(requestsQueue, true, false, false, false, requestsQueueArguments()); err != nil {
		conn.Close()
		return nil, fmt.Errorf("черга %s: %w", requestsQueue, err)
	}
	if _, err := ch.QueueDeclare(responsesQueue, true, false, false, false, queueArguments()); err != nil {
		conn.Close()
		return nil, fmt.Errorf("черга %s: %w", responsesQueue, err)
	}
	return conn, nil
}

// newPublishChannel opens a channel for requests in confirm mode:
// RabbitMQ confirms every published message.
func newPublishChannel(conn *amqp.Connection) (*amqp.Channel, error) {
	ch, err := conn.Channel()
	if err != nil {
		return nil, fmt.Errorf("канал RabbitMQ: %w", err)
	}
	if err := ch.Confirm(false); err != nil {
		ch.Close()
		return nil, fmt.Errorf("режим підтверджень RabbitMQ: %w", err)
	}
	return ch, nil
}

// publishRequest puts a new weather request into weather.requests and waits
// until RabbitMQ confirms it. It does not wait for the answer: answers are
// read separately by consumeResponses.
func publishRequest(ctx context.Context, ch *amqp.Channel) (string, error) {
	// A random id, so that the request can be found in the logs of both services.
	requestID := rand.Text()
	body, err := newRequest(requestID, time.Now())
	if err != nil {
		return "", fmt.Errorf("запит у JSON: %w", err)
	}

	ctx, cancel := context.WithTimeout(ctx, publishTimeout)
	defer cancel()

	confirmation, err := ch.PublishWithDeferredConfirmWithContext(ctx, "", requestsQueue, false, false,
		amqp.Publishing{
			ContentType:  "application/json",
			DeliveryMode: amqp.Persistent, // stored on disk
			Body:         body,
		})
	if err != nil {
		return "", fmt.Errorf("надсилання запиту: %w", err)
	}
	acked, err := confirmation.WaitContext(ctx)
	if err != nil {
		return "", fmt.Errorf("RabbitMQ не підтвердив запит за %s: %w", publishTimeout, err)
	}
	if !acked {
		return "", errors.New("RabbitMQ не прийняв запит")
	}
	return requestID, nil
}

// consumeResponses reads weather.responses until the connection breaks.
// A response is acknowledged only after it was handled (saved to the database).
func consumeResponses(
	ctx context.Context,
	conn *amqp.Connection,
	save func(context.Context, WeatherRecord) (bool, error),
) error {
	ch, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("канал RabbitMQ: %w", err)
	}
	defer ch.Close()

	// Take one response at a time: the next one comes only after ack of the previous one.
	if err := ch.Qos(1, 0, false); err != nil {
		return fmt.Errorf("налаштування каналу: %w", err)
	}
	// autoAck=false: we acknowledge each response ourselves.
	deliveries, err := ch.Consume(responsesQueue, "", false, false, false, false, nil)
	if err != nil {
		return fmt.Errorf("читання черги %s: %w", responsesQueue, err)
	}
	log.Printf("читаю відповіді з черги %s", responsesQueue)

	for delivery := range deliveries {
		switch handleResponse(ctx, delivery.Body, save) {
		case ackResponse:
			err = delivery.Ack(false)
		case rejectResponse:
			err = delivery.Reject(false) // requeue=false: remove the message
		case retryResponse:
			// Give the database time to recover. The delivery limit of the queue
			// stops the repeats after 5 attempts.
			time.Sleep(retryDelay)
			err = delivery.Nack(false, true) // requeue=true: deliver it again
		}
		if err != nil {
			return fmt.Errorf("підтвердження відповіді: %w", err)
		}
	}
	// The channel of deliveries is closed when the connection to RabbitMQ breaks.
	return errors.New("з'єднання з RabbitMQ закрито")
}
