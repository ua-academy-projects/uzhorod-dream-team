package model

type QueueType string

const (
	QueueRabbitMQ QueueType = "rabbitmq"
	QueuePGMQ     QueueType = "pgmq"
)

type Dependencies struct {
}
