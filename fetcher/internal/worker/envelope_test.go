package worker

import (
	"encoding/json"
	"testing"
	"time"
)

func TestParseHeaders(t *testing.T) {
	h := parseHeaders([]byte(`{"correlationId":"abc","replyTo":"weather_fetch_replies","expiresAt":"2026-10-13T12:00:20Z"}`))
	if h.CorrelationID != "abc" || h.ReplyTo != "weather_fetch_replies" || h.ExpiresAt == nil {
		t.Fatalf("headers = %+v", h)
	}
	for _, raw := range []string{"", "null", "not json"} {
		if h := parseHeaders([]byte(raw)); h.ReplyTo != "" {
			t.Errorf("%q: headers = %+v, want empty", raw, h)
		}
	}
}

func TestExpired(t *testing.T) {
	at := time.Date(2026, 10, 13, 12, 0, 20, 0, time.UTC)
	h := Headers{ExpiresAt: &at}
	if h.Expired(at.Add(-time.Second)) || !h.Expired(at.Add(time.Second)) {
		t.Error("a request expires after expiresAt, not before")
	}
	if (Headers{}).Expired(at) {
		t.Error("a request without expiresAt never expires")
	}
}

func TestReplyHeadersCarryOnlyTheCorrelationID(t *testing.T) {
	raw, err := json.Marshal(Headers{CorrelationID: "abc"})
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != `{"correlationId":"abc"}` {
		t.Errorf("reply headers = %s", raw)
	}
}
