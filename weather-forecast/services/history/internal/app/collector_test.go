package app

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"weather-history/internal/api"
	"weather-history/internal/config"
	"weather-history/internal/domain"
	"weather-history/internal/testutil"
)

type fakeJobs struct {
	mu   sync.Mutex
	jobs map[string]domain.Job
}

func (s *fakeJobs) CreateJob(_ context.Context, r domain.WeatherRequest) (domain.Job, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.jobs == nil {
		s.jobs = make(map[string]domain.Job)
	}
	for id, j := range s.jobs {
		if j.Status == "queued" && !time.Now().Before(j.ExpiresAt) {
			j.Status = "failed"
			s.jobs[id] = j
		}
		if j.Status == "queued" && j.Type == r.Type {
			return j, &domain.APIError{Status: 409, Message: "Already queued", RequestID: j.RequestID}
		}
	}
	j := domain.Job{RequestID: r.RequestID, Type: r.Type, Status: "queued", ExpiresAt: r.ExpiresAt, Request: r}
	s.jobs[r.RequestID] = j
	return j, nil
}

func (s *fakeJobs) GetJob(_ context.Context, id string) (domain.Job, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	j, ok := s.jobs[id]
	if !ok {
		return j, pgx.ErrNoRows
	}
	return j, nil
}

func (s *fakeJobs) MarkPublished(context.Context, string) error { return nil }

func (s *fakeJobs) ExpireJobs(context.Context) error { return nil }

func (s *fakeJobs) UnpublishedJobs(context.Context) ([]domain.WeatherRequest, error) { return nil, nil }

type fakePublisher struct {
	publish func(context.Context, domain.WeatherRequest) error
}

func (p fakePublisher) Publish(ctx context.Context, r domain.WeatherRequest) error {
	return p.publish(ctx, r)
}

func testCollector(p domain.JobPublisher) *Collector {
	return &Collector{store: &testutil.MemoryStore{}, jobs: &fakeJobs{}, publisher: p,
		config: config.Config{City: "Uzhhorod", Latitude: 48.6167, Longitude: 22.3, JobTimeout: 120 * time.Second}}
}

func TestQueuedHTTPAndPersistentBusyGuard(t *testing.T) {
	var count atomic.Int32
	p := fakePublisher{func(context.Context, domain.WeatherRequest) error { count.Add(1); return nil }}
	c := testCollector(p)
	handler := api.NewHandler(c.store, c, "", nil)
	first := httptest.NewRecorder()
	handler.ServeHTTP(first, httptest.NewRequest("POST", "/api/collect", nil))
	if first.Code != 202 {
		t.Fatalf("%d %s", first.Code, first.Body.String())
	}
	var accepted map[string]string
	if err := json.Unmarshal(first.Body.Bytes(), &accepted); err != nil {
		t.Fatal(err)
	}
	id := accepted["request_id"]
	if !domain.UUIDPattern.MatchString(id) {
		t.Fatal("missing UUID")
	}
	// A fresh Collector shares the persisted guard, without an in-memory TryLock.
	restarted := &Collector{store: c.store, jobs: c.jobs, publisher: p, config: c.config}
	if _, err := restarted.Collect(context.Background()); err == nil || count.Load() != 1 {
		t.Fatal("parallel job was published")
	}
	for path, code := range map[string]int{"/api/jobs/" + id: 200, "/api/jobs/not-a-uuid": 400, "/api/jobs/00000000-0000-0000-0000-000000000000": 404} {
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest("GET", path, nil))
		if response.Code != code {
			t.Fatalf("%s: %d", path, response.Code)
		}
	}
	// Temperature sync is a single task and does not conflict with current collection.
	var ranges []domain.TemperatureRange
	c.publisher = fakePublisher{func(_ context.Context, r domain.WeatherRequest) error { ranges = r.Ranges; return nil }}
	if _, err := c.SyncTemperature(context.Background(), 30); err != nil || len(ranges) != 1 || ranges[0].End.Sub(ranges[0].Start) != 24*time.Hour {
		t.Fatalf("hourly sync: %v %v", ranges, err)
	}
}

func TestUnconfirmedPublicationReturns503(t *testing.T) {
	c := testCollector(fakePublisher{func(context.Context, domain.WeatherRequest) error { return errors.New("no confirm") }})
	response := httptest.NewRecorder()
	api.NewHandler(c.store, c, "", nil).ServeHTTP(response, httptest.NewRequest("POST", "/api/collect", nil))
	if response.Code != 503 || !strings.Contains(response.Body.String(), "request_id") {
		t.Fatalf("%d %s", response.Code, response.Body.String())
	}
}

func TestSchedulerContinuesAfterPublicationErrorAndExpiry(t *testing.T) {
	var attempts atomic.Int32
	published := make(chan struct{}, 1)
	c := testCollector(fakePublisher{func(context.Context, domain.WeatherRequest) error {
		if attempts.Add(1) == 1 {
			return errors.New("broker unavailable")
		}
		select {
		case published <- struct{}{}:
		default:
		}
		return nil
	}})
	c.config.JobTimeout = 20 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { defer close(done); RunScheduler(ctx, c, 10*time.Millisecond) }()
	defer func() { cancel(); <-done }()
	select {
	case <-published:
	case <-time.After(2 * time.Second):
		t.Fatal("scheduler did not recover")
	}
}
