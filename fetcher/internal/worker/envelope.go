package worker

import (
	"encoding/json"
	"log/slog"
	"time"
)

// Headers of a pgmq message: what AMQP keeps in message properties. The message itself is the
// same JSON Request as over RabbitMQ.
//
//	{"correlationId": "…", "replyTo": "weather_fetch_replies", "expiresAt": "2026-10-13T12:00:20Z"}
type Headers struct {
	CorrelationID string     `json:"correlationId"`
	ReplyTo       string     `json:"replyTo,omitempty"`
	ExpiresAt     *time.Time `json:"expiresAt,omitempty"`
}

// parseHeaders decodes the headers column; NULL or invalid JSON gives empty headers (no ReplyTo).
func parseHeaders(raw []byte) Headers {
	var h Headers
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &h); err != nil {
			slog.Warn("invalid message headers", "error", err)
			return Headers{}
		}
	}
	return h
}

// Expired reports whether nobody waits for the reply any more (pgmq has no per-message TTL).
func (h Headers) Expired(now time.Time) bool {
	return h.ExpiresAt != nil && now.After(*h.ExpiresAt)
}

// encodeReply turns a Reply into the JSON body that goes back to the caller.
func encodeReply(r Reply) []byte {
	body, err := json.Marshal(r)
	if err != nil {
		slog.Error("cannot encode reply", "error", err)
		return []byte(`{"ok":false,"error":"Internal error","kind":"internal"}`)
	}
	return body
}
