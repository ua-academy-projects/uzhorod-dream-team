package postgres

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"

	"weather-history/internal/api"
	"weather-history/internal/config"
	"weather-history/internal/domain"
	rediscache "weather-history/internal/storage/redis"
	"weather-history/internal/testutil"
)

type preferenceTestBackend struct {
	store   domain.PreferenceStore
	advance func(time.Duration)
	ttl     func(string) time.Duration
	fail    func()
}

func testPreferenceBackends(t *testing.T, test func(*testing.T, preferenceTestBackend)) {
	t.Helper()
	for _, backend := range []string{config.BackendRabbitMQRedis, config.BackendPostgres} {
		t.Run(backend, func(t *testing.T) {
			if backend == config.BackendRabbitMQRedis {
				mini := miniredis.RunT(t)
				mini.RequireAuth("test-only-password")
				client := rediscache.NewClient(config.Config{RedisAddr: mini.Addr(), RedisPassword: "test-only-password"})
				t.Cleanup(func() { _ = client.Close() })
				test(t, preferenceTestBackend{
					store: rediscache.New(client), advance: mini.FastForward,
					ttl: func(id string) time.Duration { return mini.TTL("session:" + id) }, fail: mini.Close,
				})
				return
			}
			store := postgresTestStore(t)
			test(t, preferenceTestBackend{
				store: store,
				advance: func(duration time.Duration) {
					if _, err := store.pool.Exec(context.Background(), "UPDATE weather_preferences SET expires_at=expires_at-$1::bigint*INTERVAL '1 second'", int64(duration/time.Second)); err != nil {
						t.Fatal(err)
					}
				},
				ttl: func(id string) time.Duration {
					var seconds float64
					if err := store.pool.QueryRow(context.Background(), "SELECT EXTRACT(EPOCH FROM expires_at-clock_timestamp())::double precision FROM weather_preferences WHERE session_id=$1", id).Scan(&seconds); err != nil {
						t.Fatal(err)
					}
					return time.Duration(seconds * float64(time.Second))
				},
				fail: func() {
					if _, err := store.pool.Exec(context.Background(), "DROP TABLE weather_preferences"); err != nil {
						t.Fatal(err)
					}
				},
			})
		})
	}
}

func preferenceRequest(handler http.Handler, method, body string, cookie *http.Cookie) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, "/api/preferences", strings.NewReader(body))
	if cookie != nil {
		request.AddCookie(cookie)
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

func savedTheme(t *testing.T, response *httptest.ResponseRecorder, want string) {
	t.Helper()
	var p domain.Preferences
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &p) != nil || p.Theme != want {
		t.Fatalf("response %d %s, want %s", response.Code, response.Body.String(), want)
	}
	if response.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("preferences must not be cached")
	}
}

func TestPreferencesSessionsAndExpiry(t *testing.T) {
	testPreferenceBackends(t, func(t *testing.T, backend preferenceTestBackend) {
		handler := api.NewHandler(&testutil.MemoryStore{}, nil, "", api.NewPreferenceHandler(backend.store, true))
		first := preferenceRequest(handler, "GET", "", nil)
		savedTheme(t, first, "light")
		cookie := first.Result().Cookies()[0]
		if !domain.SessionPattern.MatchString(cookie.Value) || cookie.Path != "/" || !cookie.HttpOnly || !cookie.Secure || cookie.SameSite != http.SameSiteLaxMode || cookie.MaxAge != 2592000 || cookie.Domain != "" {
			t.Fatalf("invalid cookie attributes: %+v", cookie)
		}
		savedTheme(t, preferenceRequest(handler, "PUT", `{"theme":"dark"}`, cookie), "dark")
		savedTheme(t, preferenceRequest(handler, "GET", "", cookie), "dark")
		second := preferenceRequest(handler, "GET", "", nil)
		savedTheme(t, second, "light")
		if second.Result().Cookies()[0].Value == cookie.Value {
			t.Fatal("sessions must be independent")
		}
		backend.advance(20 * 24 * time.Hour)
		renewed := preferenceRequest(handler, "GET", "", cookie)
		savedTheme(t, renewed, "dark")
		if ttl := backend.ttl(cookie.Value); ttl > domain.SessionLifetime || ttl < domain.SessionLifetime-time.Second {
			t.Fatal("TTL not renewed")
		}
		if renewed.Result().Cookies()[0].MaxAge != cookie.MaxAge {
			t.Fatal("cookie lifetime not renewed")
		}
		backend.advance(domain.SessionLifetime + time.Second)
		savedTheme(t, preferenceRequest(handler, "GET", "", cookie), "light")
		invalid := preferenceRequest(handler, "GET", "", &http.Cookie{Name: "weather_session", Value: "../../invalid"})
		savedTheme(t, invalid, "light")
		if !domain.SessionPattern.MatchString(invalid.Result().Cookies()[0].Value) {
			t.Fatal("invalid ID not replaced")
		}
	})
}

func TestPreferencesInvalidInputAndUnavailable(t *testing.T) {
	testPreferenceBackends(t, func(t *testing.T, backend preferenceTestBackend) {
		handler := api.NewHandler(&testutil.MemoryStore{}, nil, "", api.NewPreferenceHandler(backend.store, false))
		first := preferenceRequest(handler, "GET", "", nil)
		cookie := first.Result().Cookies()[0]
		if cookie.Secure {
			t.Fatal("HTTP cookie must not be Secure by default")
		}
		for _, body := range []string{`{"theme":"blue"}`, `{}`, `null`, `{"theme":null}`, `{"theme":1}`, `{"theme":"dark","other":1}`, `{"theme":"dark"} {}`, `{`, strings.Repeat("x", 1025)} {
			response := preferenceRequest(handler, "PUT", body, cookie)
			if response.Code != 400 || len(response.Result().Cookies()) != 0 {
				t.Fatalf("invalid body accepted: %s", body)
			}
		}
		savedTheme(t, preferenceRequest(handler, "GET", "", cookie), "light")
		backend.fail()
		for _, method := range []string{"GET", "PUT"} {
			start := time.Now()
			response := preferenceRequest(handler, method, `{"theme":"dark"}`, cookie)
			if response.Code != 503 || len(response.Result().Cookies()) != 0 {
				t.Fatalf("preferences unavailable: %d", response.Code)
			}
			if time.Since(start) > 3*time.Second {
				t.Fatal("preferences operation timeout exceeded")
			}
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest("GET", "/api/history", nil))
		if response.Code != 200 {
			t.Fatal("preferences failure must not break weather reads")
		}
		if preferenceRequest(handler, "DELETE", "", cookie).Code != 405 {
			t.Fatal("unsupported method accepted")
		}
	})
}

func TestPreferencesConcurrentReadDoesNotOverwrite(t *testing.T) {
	testPreferenceBackends(t, func(t *testing.T, backend preferenceTestBackend) {
		handler := api.NewPreferenceHandler(backend.store, false)
		first := preferenceRequest(handler, "GET", "", nil)
		cookie := first.Result().Cookies()[0]
		done := make(chan struct{})
		go func() {
			defer close(done)
			for range 40 {
				preferenceRequest(handler, "GET", "", cookie)
			}
		}()
		for range 40 {
			savedTheme(t, preferenceRequest(handler, "PUT", `{"theme":"dark"}`, cookie), "dark")
		}
		<-done
		savedTheme(t, preferenceRequest(handler, "GET", "", cookie), "dark")
	})
}
