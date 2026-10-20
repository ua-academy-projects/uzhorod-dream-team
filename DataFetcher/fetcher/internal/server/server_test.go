package server

import (
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"data-monitor/fetcher/internal/client"
)

func TestDataUnavailableAndAvailable(t *testing.T) {
	store := NewStore()
	handler := Handler(store)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest("GET", "/data", nil))
	if response.Code != 503 || !strings.Contains(response.Body.String(), "data is not available yet") {
		t.Fatalf("unexpected response: %d %s", response.Code, response.Body)
	}
	store.Set("btc", client.Value{Value: 42, Timestamp: time.Now().UTC()})
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest("GET", "/data", nil))
	if response.Code != 200 || !strings.Contains(response.Body.String(), `"value":42`) {
		t.Fatalf("unexpected response: %d %s", response.Code, response.Body)
	}
}
func TestConcurrentStoreAccess(t *testing.T) {
	store := NewStore()
	var group sync.WaitGroup
	for i := 0; i < 20; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			for j := 0; j < 100; j++ {
				store.Set("btc", client.Value{Value: float64(j)})
				store.Get("btc")
			}
		}()
	}
	group.Wait()
}
