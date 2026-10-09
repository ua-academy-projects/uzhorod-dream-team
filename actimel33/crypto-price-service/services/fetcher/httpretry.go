package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// fatalUpstream is a response that a retry cannot change (4xx except 429).
type fatalUpstream struct{ status int }

func (e *fatalUpstream) Error() string {
	return fmt.Sprintf("upstream responded %d", e.status)
}

type retryClient struct {
	client   *http.Client
	attempts int
}

func newRetryClient(timeout time.Duration, attempts int) *retryClient {
	return &retryClient{
		client:   &http.Client{Timeout: timeout},
		attempts: attempts,
	}
}

// getJSON retries only what a second attempt could fix: 429, 5xx, network
// failures and timeouts. Ordinary 4xx responses return immediately.
func (r *retryClient) getJSON(url string, out any) error {
	var lastErr error

	for attempt := 0; attempt < r.attempts; attempt++ {
		resp, err := r.client.Get(url)
		if err != nil {
			lastErr = err
		} else {
			status := resp.StatusCode
			if status >= 400 && status < 500 && status != http.StatusTooManyRequests {
				resp.Body.Close()
				return &fatalUpstream{status: status}
			}
			if status >= 200 && status < 300 {
				err := json.NewDecoder(resp.Body).Decode(out)
				resp.Body.Close()
				if err != nil {
					return fmt.Errorf("decoding upstream response: %w", err)
				}
				return nil
			}
			resp.Body.Close()
			lastErr = fmt.Errorf("upstream responded %d", status)
		}

		if attempt < r.attempts-1 {
			time.Sleep(time.Duration(1<<attempt) * 500 * time.Millisecond)
		}
	}
	return lastErr
}
