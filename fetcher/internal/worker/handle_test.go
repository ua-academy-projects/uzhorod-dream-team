package worker

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"fetcher/internal/openmeteo"
)

type fakeWeather struct {
	err  error
	days int
}

func (f *fakeWeather) FetchCurrent(_ context.Context, loc openmeteo.Location) (openmeteo.Observation, error) {
	temp := 5.0
	return openmeteo.Observation{
		LocationName: loc.Name,
		ObservedAt:   time.Date(2025, 1, 1, 12, 0, 0, 0, time.UTC),
		Temperature:  &temp,
		Source:       "current",
	}, f.err
}

func (f *fakeWeather) FetchRecentHistory(_ context.Context, _ openmeteo.Location, days int) ([]openmeteo.Observation, error) {
	f.days = days
	return nil, f.err
}

const berlin = `"location":{"name":"Berlin","latitude":52.52,"longitude":13.41}`

// handle runs Handle and decodes the reply the way the History service sees it on the wire
func handle(t *testing.T, w Weather, body string) map[string]any {
	t.Helper()
	raw, err := json.Marshal(Handle(context.Background(), w, []byte(body)))
	if err != nil {
		t.Fatal(err)
	}
	var reply map[string]any
	if err := json.Unmarshal(raw, &reply); err != nil {
		t.Fatal(err)
	}
	return reply
}

func TestCurrentReturnsCamelCaseJSONWithNulls(t *testing.T) {
	reply := handle(t, &fakeWeather{}, `{"type":"current",`+berlin+`}`)
	if reply["ok"] != true {
		t.Fatalf("reply = %v", reply)
	}
	data := reply["data"].(map[string]any)
	if data["locationName"] != "Berlin" || data["observedAt"] != "2025-01-01T12:00:00Z" {
		t.Errorf("unexpected data: %v", data)
	}
	if v, ok := data["humidity"]; !ok || v != nil {
		t.Errorf("humidity should be present and null, got %v (present=%v)", v, ok)
	}
}

func TestInvalidRequestsAreBadRequests(t *testing.T) {
	for _, body := range []string{
		`not json`,
		`{"type":"current"}`,
		`{"type":"current","location":{"name":"X","latitude":100,"longitude":0}}`,
		`{"type":"current","location":{"name":"X","longitude":0}}`,
		`{"type":"nope",` + berlin + `}`,
		`{"type":"history",` + berlin + `,"days":0}`,
		`{"type":"history",` + berlin + `,"days":93}`,
		`{"type":"history",` + berlin + `,"days":1.5}`,
	} {
		if reply := handle(t, &fakeWeather{}, body); reply["ok"] != false || reply["kind"] != KindBadRequest {
			t.Errorf("%s: reply = %v, want bad_request", body, reply)
		}
	}
}

func TestHistoryDefaultsToSevenDaysAndReturnsEmptyList(t *testing.T) {
	fake := &fakeWeather{}
	reply := handle(t, fake, `{"type":"history",`+berlin+`}`)
	if fake.days != 7 {
		t.Errorf("days = %d, want 7", fake.days)
	}
	if list, ok := reply["data"].([]any); !ok || len(list) != 0 {
		t.Errorf("data = %#v, want an empty list (not null)", reply["data"])
	}
}

func TestUpstreamErrorIsReported(t *testing.T) {
	fake := &fakeWeather{err: &openmeteo.FetcherError{Message: "boom"}}
	reply := handle(t, fake, `{"type":"current",`+berlin+`}`)
	if reply["ok"] != false || reply["kind"] != KindUpstream || reply["error"] != "boom" {
		t.Errorf("reply = %v", reply)
	}
}
