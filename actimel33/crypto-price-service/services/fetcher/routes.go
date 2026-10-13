package main

import (
	"encoding/json"
	"log"
	"net/http"
)

// Only a health check: prices travel through the queue, so the fetcher offers
// no HTTP path to CoinGecko that would bypass deduplication.
type server struct {
	backend string
}

func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	body := map[string]string{"status": "ok", "backend": s.backend}
	if err := json.NewEncoder(w).Encode(body); err != nil {
		log.Printf("[fetcher] writing response: %v", err)
	}
}

func (s *server) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	return mux
}
