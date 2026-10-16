package postgresqueue

import (
	"encoding/json"
	"time"
)

type message struct {
	CorrelationID string          `json:"correlation_id"`
	Deadline      time.Time       `json:"deadline"`
	Payload       json.RawMessage `json:"payload"`
}
