package main

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPostgresPreferencesMigrationAndPersistence(t *testing.T) {
	store := postgresTestStore(t)
	ctx := context.Background()
	handler := &preferenceHandler{store: store}
	first := preferenceRequest(handler, "GET", "", nil)
	savedTheme(t, first, "light")
	cookie := first.Result().Cookies()[0]
	savedTheme(t, preferenceRequest(handler, "PUT", `{"theme":"dark"}`, cookie), "dark")
	var before, after time.Time
	if err := store.pool.QueryRow(ctx, "SELECT expires_at FROM weather_preferences WHERE session_id=$1", cookie.Value).Scan(&before); err != nil {
		t.Fatal(err)
	}
	migration, err := os.ReadFile("../migrations/006_postgres_preferences.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.pool.Exec(ctx, string(migration)); err != nil {
		t.Fatal(err)
	}
	if err := store.pool.QueryRow(ctx, "SELECT expires_at FROM weather_preferences WHERE session_id=$1", cookie.Value).Scan(&after); err != nil || !before.Equal(after) {
		t.Fatalf("migration changed the saved expiry: %v", err)
	}
	pool, err := pgxpool.NewWithConfig(ctx, store.pool.Config())
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	restarted := &preferenceHandler{store: &Store{pool: pool}}
	savedTheme(t, preferenceRequest(restarted, "GET", "", cookie), "dark")
}

func TestPostgresPreferencesCleanup(t *testing.T) {
	store := postgresTestStore(t)
	ctx := context.Background()
	expiredID, activeID := strings.Repeat("a", 64), strings.Repeat("b", 64)
	for _, id := range []string{expiredID, activeID} {
		if err := store.SetPreferences(ctx, id, Preferences{Theme: "dark"}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := store.pool.Exec(ctx, "UPDATE weather_preferences SET expires_at=NOW()-INTERVAL '1 second' WHERE session_id=$1", expiredID); err != nil {
		t.Fatal(err)
	}
	if err := store.prunePreferences(ctx); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := store.pool.QueryRow(ctx, "SELECT count(*) FROM weather_preferences").Scan(&count); err != nil || count != 1 {
		t.Fatalf("cleanup did not remove only the expired row: %v", err)
	}
	preferences, err := store.GetPreferences(ctx, activeID)
	if err != nil || preferences.Theme != "dark" {
		t.Fatal("cleanup changed active preferences")
	}
	preferences, err = store.GetPreferences(ctx, expiredID)
	if err != nil || preferences.Theme != "light" {
		t.Fatal("missing preferences did not return the default")
	}
}

func TestPostgresPreferencesCleanupPreservesConcurrentRenewal(t *testing.T) {
	store := postgresTestStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	id := strings.Repeat("c", 64)
	if err := store.SetPreferences(ctx, id, Preferences{Theme: "dark"}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.pool.Exec(ctx, "UPDATE weather_preferences SET expires_at=NOW()-INTERVAL '1 second' WHERE session_id=$1", id); err != nil {
		t.Fatal(err)
	}
	renewal, err := store.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer renewal.Rollback(context.Background())
	if _, err := renewal.Exec(ctx, "SELECT session_id FROM weather_preferences WHERE session_id=$1 FOR UPDATE", id); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- store.prunePreferences(ctx) }()
	// Ensure cleanup has reached the row lock before renewing the session.
	for {
		var waiting bool
		if err := store.pool.QueryRow(ctx, `SELECT EXISTS (
 SELECT FROM pg_stat_activity WHERE query='DELETE FROM weather_preferences WHERE expires_at<=NOW()'
 AND wait_event_type='Lock' AND state='active' AND datname=current_database())`).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		select {
		case err := <-done:
			t.Fatalf("cleanup returned before the locked row was renewed: %v", err)
		case <-ctx.Done():
			t.Fatal("cleanup did not reach the row lock")
		case <-time.After(10 * time.Millisecond):
		}
	}
	if _, err := renewal.Exec(ctx, "UPDATE weather_preferences SET expires_at=NOW()+INTERVAL '30 days' WHERE session_id=$1", id); err != nil {
		t.Fatal(err)
	}
	if err := renewal.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	preferences, err := store.GetPreferences(ctx, id)
	if err != nil || preferences.Theme != "dark" {
		t.Fatal("cleanup removed concurrently renewed preferences")
	}
}

func TestPostgresPreferencesConvertsJSONB(t *testing.T) {
	store := postgresTestStore(t)
	ctx := context.Background()
	if _, err := store.pool.Exec(ctx, `DROP TABLE weather_preferences;
CREATE TABLE weather_preferences (
 session_id TEXT PRIMARY KEY, preferences JSONB NOT NULL CHECK (jsonb_typeof(preferences)='object'),
 expires_at TIMESTAMPTZ NOT NULL);
INSERT INTO weather_preferences VALUES ('conversion-session','{"theme":"dark"}', '2030-01-01T00:00:00Z');`); err != nil {
		t.Fatal(err)
	}
	migration, err := os.ReadFile("../migrations/006_postgres_preferences.sql")
	if err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if _, err := store.pool.Exec(ctx, string(migration)); err != nil {
			t.Fatal(err)
		}
	}
	var theme, dataType string
	var expires time.Time
	err = store.pool.QueryRow(ctx, `SELECT preferences OPERATOR(public.->) 'theme',
 pg_typeof(preferences)::text, expires_at FROM weather_preferences WHERE session_id='conversion-session'`).Scan(&theme, &dataType, &expires)
	if err != nil || theme != "dark" || !strings.Contains(dataType, "hstore") || expires.Year() != 2030 {
		t.Fatalf("conversion changed session data: %s %s %s %v", theme, dataType, expires, err)
	}
}
