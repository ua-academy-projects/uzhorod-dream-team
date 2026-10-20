package fetcher

import "testing"

func TestRequestQueueName(t *testing.T) {
	if RequestQueue != "fetcher.requests" {
		t.Fatalf("unexpected request queue: %q", RequestQueue)
	}
}
