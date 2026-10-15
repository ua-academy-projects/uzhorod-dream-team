package syncprotocol

import (
	"context"
	"encoding/json"
)

type Handler interface {
	Handle(context.Context, Request) (json.RawMessage, error)
}
