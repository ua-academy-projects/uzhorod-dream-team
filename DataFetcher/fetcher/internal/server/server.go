package server

import (
	"encoding/json"
	"net/http"
	"sort"
	"sync"
	"time"

	"data-monitor/fetcher/internal/client"
)

type Item struct {
	Source string `json:"source"`
	client.Value
	Timestamp time.Time `json:"timestamp"`
}

type Store struct {
	mu     sync.RWMutex
	latest map[string]client.Value
}

func NewStore() *Store {
	return &Store{latest: make(map[string]client.Value)}
}

func (s *Store) Set(source string, value client.Value) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.latest[source] = value
}

func (s *Store) Get(source string) (Item, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	value, ok := s.latest[source]
	if !ok {
		return Item{}, false
	}
	return Item{Source: source, Value: value}, true
}

func (s *Store) All() []Item {
	s.mu.RLock()
	defer s.mu.RUnlock()
	items := make([]Item, 0, len(s.latest))
	for name, value := range s.latest {
		items = append(items, Item{Source: name, Value: value})
	}
	sort.Slice(items, func(i, j int) bool { return items[i].Source < items[j].Source })
	return items
}

func Handler(store *Store) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		write(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	mux.HandleFunc("GET /data", func(w http.ResponseWriter, r *http.Request) {
		if name := r.URL.Query().Get("source"); name != "" {
			item, ok := store.Get(name)
			if !ok {
				write(w, http.StatusNotFound, map[string]string{
					"error": "unknown source or no data yet",
				})
				return
			}
			write(w, http.StatusOK, item)
			return
		}

		items := store.All()
		if len(items) == 0 {
			write(w, http.StatusServiceUnavailable, map[string]string{
				"error": "data is not available yet",
			})
			return
		}
		write(w, http.StatusOK, items)
	})

	return mux
}

func write(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
