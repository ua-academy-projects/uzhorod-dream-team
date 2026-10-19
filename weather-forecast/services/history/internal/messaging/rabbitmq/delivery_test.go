package rabbitmq

import (
	"context"
	"errors"
	"testing"

	amqp "github.com/rabbitmq/amqp091-go"

	"weather-history/internal/domain"
)

type fakeAcks struct{ acked, rejected bool }

func (a *fakeAcks) Ack(uint64, bool) error { a.acked = true; return nil }

func (a *fakeAcks) Nack(uint64, bool, bool) error { return nil }

func (a *fakeAcks) Reject(uint64, bool) error { a.rejected = true; return nil }

type fakeResponseStore struct{ apply func() error }

func (s fakeResponseStore) ApplyResponse(context.Context, []byte) error { return s.apply() }

func TestResponseAckAfterCommit(t *testing.T) {
	for _, fail := range []bool{false, true} {
		acks := &fakeAcks{}
		d := amqp.Delivery{Acknowledger: acks, CorrelationId: "00000000-0000-0000-0000-000000000001", Type: domain.CurrentWeather,
			Body: []byte(`{"request_id":"00000000-0000-0000-0000-000000000001","type":"current_weather","status":"completed"}`)}
		store := fakeResponseStore{func() error {
			if acks.acked {
				t.Fatal("ack before commit")
			}
			if fail {
				return errors.New("transaction failed")
			}
			return nil
		}}
		err := applyDelivery(context.Background(), store, d)
		if (err != nil) != fail || acks.acked == fail {
			t.Fatal("invalid ack behavior")
		}
	}
}
