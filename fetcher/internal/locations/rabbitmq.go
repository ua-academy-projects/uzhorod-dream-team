package locations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"fetcher/internal/rabbitmq"
)

type MessageHandler struct{ service Service }

func NewMessageHandler(service Service) *MessageHandler { return &MessageHandler{service: service} }

func (h *MessageHandler) Handle(ctx context.Context, request rabbitmq.Request) (json.RawMessage, error) {
	if request.Version != rabbitmq.Version {
		return nil, errors.New("unsupported request version")
	}
	if request.Deadline.IsZero() {
		return nil, errors.New("request deadline is required")
	}
	ctx, cancel := context.WithDeadline(ctx, request.Deadline)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	var result any
	var err error
	switch request.Operation {
	case rabbitmq.ListLocations:
		result, err = h.service.GetLocations(ctx)
	case rabbitmq.LatestLocations:
		result, err = h.service.GetLocationsLatest(ctx)
	case rabbitmq.LocationMeasurements:
		if request.LocationID <= 0 {
			return nil, errors.New("invalid location ID")
		}
		for _, value := range []string{request.From, request.To} {
			if value != "" {
				if _, err := time.Parse(time.RFC3339, value); err != nil {
					return nil, errors.New("invalid measurement time range")
				}
			}
		}
		result, err = h.service.GetLocationMeasurements(ctx, request.LocationID, request.From, request.To)
	default:
		return nil, fmt.Errorf("unknown operation %q", request.Operation)
	}
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return json.Marshal(result)
}
