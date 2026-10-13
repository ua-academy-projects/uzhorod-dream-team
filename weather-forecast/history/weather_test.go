package main

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
	amqp "github.com/rabbitmq/amqp091-go"
)

const validWeather = `{"city":"Uzhhorod","latitude":48.6167,"longitude":22.3,"temperature_c":16.2,"humidity_percent":70,"wind_speed_kmh":9.4,"weather_time":"2026-09-30T09:15:00Z"}`

func TestWeatherValidation(t *testing.T) {
	for _, body := range []string{`{}`, strings.Replace(validWeather, `"humidity_percent":70`, `"humidity_percent":null`, 1),
		strings.Replace(validWeather, `"humidity_percent":70`, `"humidity_percent":101`, 1),
		strings.Replace(validWeather, "09:15:00Z", "09:15:00+03:00", 1), validWeather + "{}"} {
		if _, err := decodeWeather([]byte(body)); err == nil {
			t.Fatalf("accepted invalid body: %s", body)
		}
	}
	if _, err := decodeWeather([]byte(validWeather)); err != nil {
		t.Fatal(err)
	}
}

type fakeJobs struct {
	mu   sync.Mutex
	jobs map[string]Job
}

func (s *fakeJobs) CreateJob(_ context.Context, r WeatherRequest) (Job, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.jobs == nil {
		s.jobs = make(map[string]Job)
	}
	for id, j := range s.jobs {
		if j.Status == "queued" && !time.Now().Before(j.ExpiresAt) {
			j.Status = "failed"
			s.jobs[id] = j
		}
		if j.Status == "queued" && j.Type == r.Type {
			return j, &APIError{Status: 409, Message: "Already queued", RequestID: j.RequestID}
		}
	}
	j := Job{RequestID: r.RequestID, Type: r.Type, Status: "queued", ExpiresAt: r.ExpiresAt, Request: r}
	s.jobs[r.RequestID] = j
	return j, nil
}
func (s *fakeJobs) GetJob(_ context.Context, id string) (Job, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	j, ok := s.jobs[id]
	if !ok {
		return j, pgx.ErrNoRows
	}
	return j, nil
}
func (s *fakeJobs) MarkPublished(context.Context, string) error               { return nil }
func (s *fakeJobs) ExpireJobs(context.Context) error                          { return nil }
func (s *fakeJobs) UnpublishedJobs(context.Context) ([]WeatherRequest, error) { return nil, nil }

type fakePublisher struct {
	publish func(context.Context, WeatherRequest) error
}

func (p fakePublisher) Publish(ctx context.Context, r WeatherRequest) error { return p.publish(ctx, r) }
func testCollector(p JobPublisher) *Collector {
	return &Collector{store: &memoryStore{}, jobs: &fakeJobs{}, publisher: p,
		config: Config{City: "Uzhhorod", Latitude: 48.6167, Longitude: 22.3, JobTimeout: 120 * time.Second}}
}

func TestQueuedHTTPAndPersistentBusyGuard(t *testing.T) {
	var count atomic.Int32
	p := fakePublisher{func(context.Context, WeatherRequest) error { count.Add(1); return nil }}
	c := testCollector(p)
	handler := newHandler(c.store, c, "", nil)
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
	if !uuidPattern.MatchString(id) {
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
	var ranges []temperatureRange
	c.publisher = fakePublisher{func(_ context.Context, r WeatherRequest) error { ranges = r.Ranges; return nil }}
	if _, err := c.SyncTemperature(context.Background(), 30); err != nil || len(ranges) != 1 || ranges[0].End.Sub(ranges[0].Start) != 24*time.Hour {
		t.Fatalf("hourly sync: %v %v", ranges, err)
	}
}

func TestUnconfirmedPublicationReturns503(t *testing.T) {
	c := testCollector(fakePublisher{func(context.Context, WeatherRequest) error { return errors.New("no confirm") }})
	response := httptest.NewRecorder()
	newHandler(c.store, c, "", nil).ServeHTTP(response, httptest.NewRequest("POST", "/api/collect", nil))
	if response.Code != 503 || !strings.Contains(response.Body.String(), "request_id") {
		t.Fatalf("%d %s", response.Code, response.Body.String())
	}
}

func TestSchedulerContinuesAfterPublicationErrorAndExpiry(t *testing.T) {
	var attempts atomic.Int32
	published := make(chan struct{}, 1)
	c := testCollector(fakePublisher{func(context.Context, WeatherRequest) error {
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
	go func() { defer close(done); runScheduler(ctx, c, 10*time.Millisecond) }()
	defer func() { cancel(); <-done }()
	select {
	case <-published:
	case <-time.After(2 * time.Second):
		t.Fatal("scheduler did not recover")
	}
}

func TestTemperatureResponseMustCoverAllRanges(t *testing.T) {
	start := time.Now().UTC().Truncate(time.Hour).Add(-3 * time.Hour)
	request := WeatherRequest{RequestID: "00000000-0000-0000-0000-000000000001", Type: temperatureHistory, City: "Uzhhorod",
		Ranges: []temperatureRange{{start, start.Add(time.Hour)}, {start.Add(3 * time.Hour), start.Add(3 * time.Hour)}}}
	points := []TemperaturePoint{{start, 10}, {start.Add(time.Hour), 11}, {start.Add(3 * time.Hour), 12}}
	payload := func(points []TemperaturePoint, city string) json.RawMessage {
		b, _ := json.Marshal(struct {
			City   string             `json:"city"`
			Points []TemperaturePoint `json:"points"`
		}{city, points})
		return b
	}
	response := WeatherResponse{RequestID: request.RequestID, Type: request.Type, Status: "completed", Data: payload(points, "Uzhhorod")}
	if _, saved, failure := validateResponse(request, response); failure != nil || len(saved) != 3 {
		t.Fatalf("valid response: %v", failure)
	}
	for _, data := range []json.RawMessage{payload(points[:2], "Uzhhorod"), payload(points, "Lviv"), payload(append(points, points[2]), "Uzhhorod")} {
		response.Data = data
		if _, _, failure := validateResponse(request, response); failure == nil {
			t.Fatal("invalid range accepted")
		}
	}
	response.Status = "failed"
	response.Error = &JobFailure{"provider_timeout", "Open-Meteo did not respond in time"}
	if _, saved, failure := validateResponse(request, response); failure.Code != "provider_timeout" || len(saved) != 0 {
		t.Fatal("provider error ignored")
	}
}

type fakeAcks struct{ acked, rejected bool }

func (a *fakeAcks) Ack(uint64, bool) error        { a.acked = true; return nil }
func (a *fakeAcks) Nack(uint64, bool, bool) error { return nil }
func (a *fakeAcks) Reject(uint64, bool) error     { a.rejected = true; return nil }

type fakeResponseStore struct{ apply func() error }

func (s fakeResponseStore) ApplyResponse(context.Context, []byte) error { return s.apply() }
func TestResponseAckAfterCommit(t *testing.T) {
	for _, fail := range []bool{false, true} {
		acks := &fakeAcks{}
		d := amqp.Delivery{Acknowledger: acks, CorrelationId: "00000000-0000-0000-0000-000000000001", Type: currentWeather,
			Body: []byte(`{"request_id":"00000000-0000-0000-0000-000000000001","type":"current_weather","status":"completed"}`)}
		store := fakeResponseStore{func() error {
			if acks.acked {
				t.Fatal("ack before commit")
			}
			if fail {
				return errors.New("transaction failed")
			}
			return nil
		}}
		err := applyDelivery(context.Background(), store, d)
		if (err != nil) != fail || acks.acked == fail {
			t.Fatal("invalid ack behavior")
		}
	}
}
