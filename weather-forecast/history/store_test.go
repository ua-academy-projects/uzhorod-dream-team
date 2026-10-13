package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// This optional integration test uses an isolated schema in a test database.
func TestStoreUpdatesMatchingWeatherTime(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("set TEST_DATABASE_URL to run PostgreSQL integration tests")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	config, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	schema := fmt.Sprintf("weather_test_%d", time.Now().UnixNano())
	config.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if _, err := pool.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if _, err := pool.Exec(cleanup, "DROP SCHEMA "+schema+" CASCADE"); err != nil {
			t.Errorf("cleanup: %v", err)
		}
	}()
	apply := func(name string) {
		t.Helper()
		sql, err := os.ReadFile("../migrations/" + name)
		if err != nil {
			t.Fatal(err)
		}
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx)
		if _, err := tx.Exec(ctx, string(sql)); err != nil {
			t.Fatal(err)
		}
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
	}
	apply("001_create_weather_snapshots.sql")
	apply("003_temperature_history.sql")
	apply("004_weather_jobs.sql")
	apply("004_weather_jobs.sql")
	_, err = pool.Exec(ctx, `INSERT INTO weather_snapshots
 (city, latitude, longitude, temperature_c, humidity_percent, wind_speed_kmh, weather_time, fetched_at)
 VALUES ('Uzhhorod', 48.6167, 22.3, 10, 60, 4, '2026-09-30T09:15:00Z', '2026-09-30T09:16:00Z'),
        ('Uzhhorod', 48.6167, 22.3, 11, 61, 5, '2026-09-30T09:15:00Z', '2026-09-30T09:17:00Z')`)
	if err != nil {
		t.Fatal(err)
	}
	apply("002_unique_weather_time.sql")
	apply("002_unique_weather_time.sql") // Reapplying must not duplicate the archive.
	store := &Store{pool: pool}
	previous, err := store.Latest(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if previous.ID != 2 || previous.TemperatureC != 11 {
		t.Fatalf("migration did not keep the newest duplicate: %+v", previous)
	}
	updated := previous
	updated.TemperatureC = 12
	updated.HumidityPercent = 62
	updated.WindSpeedKMH = 6
	updated.FetchedAt = previous.FetchedAt.Add(time.Minute)
	updated, err = store.Insert(ctx, updated)
	if err != nil {
		t.Fatal(err)
	}
	if updated.ID != previous.ID || updated.TemperatureC != 12 || updated.HumidityPercent != 62 || updated.WindSpeedKMH != 6 || !updated.FetchedAt.After(previous.FetchedAt) {
		t.Fatalf("matching weather time was not updated: %+v", updated)
	}
	newTime := updated
	newTime.WeatherTime = newTime.WeatherTime.Add(15 * time.Minute)
	if _, err := store.Insert(ctx, newTime); err != nil {
		t.Fatal(err)
	}
	otherCity := updated
	otherCity.City = "Lviv"
	otherCity.TemperatureC = 99
	if _, err := store.Insert(ctx, otherCity); err != nil {
		t.Fatal(err)
	}
	rows, err := store.History(ctx, 100)
	if err != nil || len(rows) != 3 {
		t.Fatalf("expected three distinct city/time snapshots, got %d: %v", len(rows), err)
	}
	older := updated
	older.WeatherTime = older.WeatherTime.Add(-time.Hour)
	older.TemperatureC = 10
	if _, err := store.Insert(ctx, older); err != nil {
		t.Fatal(err)
	}
	points, err := store.Temperature(ctx, "Uzhhorod", older.WeatherTime)
	if err != nil || len(points) != 2 {
		t.Fatalf("expected two hourly Uzhhorod points, got %+v: %v", points, err)
	}
	if points[0].TemperatureC != 10 || points[1].TemperatureC != 12 || !points[0].WeatherTime.Before(points[1].WeatherTime) || points[0].WeatherTime.Location() != time.UTC {
		t.Fatalf("incorrect city filtering, hourly averages, or ordering: %+v", points)
	}
	points, err = store.Temperature(ctx, "Uzhhorod", updated.WeatherTime)
	if err != nil || len(points) != 1 || points[0].TemperatureC != 12 {
		t.Fatalf("incorrect period filtering: %+v, %v", points, err)
	}
	imported := []TemperaturePoint{{older.WeatherTime.Truncate(time.Hour), 20}, {updated.WeatherTime.Truncate(time.Hour), 21}}
	if err := store.SaveTemperature(ctx, "Uzhhorod", imported); err != nil {
		t.Fatal(err)
	}
	imported[1].TemperatureC = 22
	if err := store.SaveTemperature(ctx, "Uzhhorod", imported); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveTemperature(ctx, "Lviv", []TemperaturePoint{{imported[0].WeatherTime, 99}}); err != nil {
		t.Fatal(err)
	}
	points, err = store.Temperature(ctx, "Uzhhorod", older.WeatherTime)
	if err != nil || len(points) != 2 || points[0].TemperatureC != 20 || points[1].TemperatureC != 22 {
		t.Fatalf("imported history should fill or replace chart values: %+v, %v", points, err)
	}
	var importedCount int
	startHour := imported[0].WeatherTime.Add(-time.Hour)
	endHour := imported[1].WeatherTime.Add(time.Hour)
	missing, err := store.MissingTemperatureHours(ctx, "Uzhhorod", startHour, endHour)
	if err != nil || len(missing) != 2 || !missing[0].Equal(startHour) || !missing[1].Equal(endHour) {
		t.Fatalf("incorrect missing hours: %v, %v", missing, err)
	}
	missing, err = store.MissingTemperatureHours(ctx, "new city", startHour, endHour)
	if err != nil || len(missing) != 4 {
		t.Fatalf("new city should require a full backfill: %v, %v", missing, err)
	}
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM temperature_history WHERE city='Uzhhorod'").Scan(&importedCount); err != nil || importedCount != 2 {
		t.Fatalf("repeated sync created duplicates: count=%d, %v", importedCount, err)
	}
	var archived int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM weather_snapshots_duplicates").Scan(&archived); err != nil || archived != 1 {
		t.Fatalf("expected one recoverable duplicate, got %d: %v", archived, err)
	}
	testJobTransactions(t, ctx, store)
}

func testJobTransactions(t *testing.T, ctx context.Context, store *Store) {
	t.Helper()
	create := func(kind string, ranges []temperatureRange) WeatherRequest {
		t.Helper()
		id, _ := newRequestID()
		request := WeatherRequest{id, kind, "Uzhhorod", 48.6167, 22.3, time.Now().UTC().Add(time.Minute), ranges}
		if _, err := store.CreateJob(ctx, request); err != nil {
			t.Fatal(err)
		}
		return request
	}
	apply := func(request WeatherRequest, data json.RawMessage, failure *JobFailure) error {
		status := "completed"
		if failure != nil {
			status = "failed"
		}
		body, _ := json.Marshal(WeatherResponse{request.RequestID, request.Type, status, data, failure})
		return store.ApplyResponse(ctx, body)
	}
	state := func(request WeatherRequest) string {
		t.Helper()
		job, err := store.GetJob(ctx, request.RequestID)
		if err != nil {
			t.Fatal(err)
		}
		return job.Status
	}
	request := create(currentWeather, nil)
	pending, err := store.UnpublishedJobs(ctx)
	if err != nil || len(pending) != 1 || pending[0].RequestID != request.RequestID {
		t.Fatalf("pending publication lost: %v %v", pending, err)
	}
	if err := apply(request, json.RawMessage(validWeather), nil); err != nil {
		t.Fatal(err)
	}
	first, _ := store.Latest(ctx)
	if state(request) != "completed" {
		t.Fatal("job not completed")
	}
	changed := first.Weather
	changed.TemperatureC = 33
	changedJSON, _ := json.Marshal(changed)
	if err := apply(request, changedJSON, nil); err != nil {
		t.Fatal(err)
	}
	duplicate, _ := store.Latest(ctx)
	if duplicate.TemperatureC != first.TemperatureC || !duplicate.FetchedAt.Equal(first.FetchedAt) {
		t.Fatal("redelivery reapplied weather")
	}

	// A SQL failure must roll back both the snapshot and processed request ID.
	request = create(currentWeather, nil)
	if _, err := store.pool.Exec(ctx, "ALTER TABLE weather_snapshots ADD CONSTRAINT test_temperature CHECK (temperature_c <> 777)"); err != nil {
		t.Fatal(err)
	}
	changed.TemperatureC = 777
	changedJSON, _ = json.Marshal(changed)
	if err := apply(request, changedJSON, nil); err == nil || state(request) != "queued" {
		t.Fatal("SQL failure marked request as processed")
	}
	if err := apply(request, json.RawMessage(validWeather), nil); err != nil || state(request) != "completed" {
		t.Fatalf("retry failed: %v", err)
	}

	hour := time.Now().UTC().Truncate(time.Hour)
	ranges := []temperatureRange{{hour.Add(-time.Hour), hour}}
	request = create(temperatureHistory, ranges)
	points := []TemperaturePoint{{ranges[0].Start, 10}, {ranges[0].End, 11}}
	payload := func(points []TemperaturePoint) json.RawMessage {
		body, _ := json.Marshal(struct {
			City   string             `json:"city"`
			Points []TemperaturePoint `json:"points"`
		}{"Uzhhorod", points})
		return body
	}
	if err := apply(request, payload(points[:1]), nil); err != nil || state(request) != "failed" {
		t.Fatalf("incomplete response handling: %v", err)
	}
	var count int
	if err := store.pool.QueryRow(ctx, "SELECT count(*) FROM temperature_history WHERE city=$1 AND weather_time >= $2", "Uzhhorod", ranges[0].Start).Scan(&count); err != nil || count != 0 {
		t.Fatal("partial history saved")
	}
	request = create(temperatureHistory, ranges)
	if err := apply(request, payload(points), nil); err != nil || state(request) != "completed" {
		t.Fatalf("hourly save: %v", err)
	}
	points[1].TemperatureC = 99
	if err := apply(request, payload(points), nil); err != nil {
		t.Fatal(err)
	}
	var temperature float64
	if err := store.pool.QueryRow(ctx, "SELECT temperature_c FROM temperature_history WHERE city=$1 AND weather_time=$2", "Uzhhorod", hour).Scan(&temperature); err != nil || temperature != 11 {
		t.Fatal("hourly redelivery changed data")
	}
	request = create(currentWeather, nil)
	if err := apply(request, nil, &JobFailure{"provider_timeout", "Open-Meteo did not respond in time"}); err != nil || state(request) != "failed" {
		t.Fatalf("provider failure: %v", err)
	}
	request = create(currentWeather, nil)
	if _, err := store.pool.Exec(ctx, "UPDATE weather_jobs SET expires_at=NOW()-interval '1 second' WHERE request_id=$1", request.RequestID); err != nil {
		t.Fatal(err)
	}
	if state(request) != "failed" {
		t.Fatal("deadline did not release collection guard")
	}
	if err := apply(request, json.RawMessage(validWeather), nil); err != nil || state(request) != "failed" {
		t.Fatal("late response resurrected expired job")
	}
	request = create(currentWeather, nil)
	if err := store.MarkPublished(ctx, request.RequestID); err != nil {
		t.Fatal(err)
	}
	pending, err = store.UnpublishedJobs(ctx)
	if err != nil || len(pending) != 0 {
		t.Fatal("confirmed job was queued for republication")
	}
}
