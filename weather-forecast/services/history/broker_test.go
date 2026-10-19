package main

import (
	"context"
	"os"
	"testing"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

// Use only an isolated test broker/vhost. Never point this at production.
func TestBrokerConfirmsAndUnroutableMessage(t *testing.T) {
	url := os.Getenv("TEST_RABBITMQ_URL")
	if url == "" {
		t.Skip("set TEST_RABBITMQ_URL to an isolated broker/vhost")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	session, err := newBroker(url).open(ctx, true)
	if err != nil {
		t.Fatal("cannot connect to test RabbitMQ")
	}
	defer session.close()
	id, _ := newRequestID()
	queue := "weather.test." + id
	if _, err := session.channel.QueueDeclare(queue, true, false, false, false, nil); err != nil {
		t.Fatal(err)
	}
	defer session.channel.QueueDelete(queue, false, false, false)
	message := amqp.Publishing{ContentType: "application/json", DeliveryMode: amqp.Persistent, Body: []byte(`{"test":true}`)}
	if err := session.confirmedPublish(ctx, queue, message); err != nil {
		t.Fatal(err)
	}
	delivery, ok, err := session.channel.Get(queue, false)
	if err != nil || !ok {
		t.Fatal("confirmed message was not delivered")
	}
	if err := delivery.Ack(false); err != nil {
		t.Fatal(err)
	}
	if err := session.confirmedPublish(ctx, queue+".missing", message); err == nil {
		t.Fatal("unroutable message was accepted")
	}
}
