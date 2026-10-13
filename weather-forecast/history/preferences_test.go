package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
)

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
	var p Preferences
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &p) != nil || p.Theme != want {
		t.Fatalf("response %d %s, want %s", response.Code, response.Body.String(), want)
	}
	if response.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("preferences must not be cached")
	}
}
func TestPreferencesSessionsAndExpiry(t *testing.T) {
	mini := miniredis.RunT(t)
	mini.RequireAuth("test-only-password")
	client := newRedisClient(Config{RedisAddr: mini.Addr(), RedisPassword: "test-only-password"})
	defer client.Close()
	handler := newHandler(&memoryStore{}, nil, "", &preferenceHandler{client: client, secure: true})
	first := preferenceRequest(handler, "GET", "", nil)
	savedTheme(t, first, "light")
	cookie := first.Result().Cookies()[0]
	if !sessionPattern.MatchString(cookie.Value) || cookie.Path != "/" || !cookie.HttpOnly || !cookie.Secure || cookie.SameSite != http.SameSiteLaxMode || cookie.MaxAge != 2592000 || cookie.Domain != "" {
		t.Fatalf("invalid cookie attributes: %+v", cookie)
	}
	savedTheme(t, preferenceRequest(handler, "PUT", `{"theme":"dark"}`, cookie), "dark")
	savedTheme(t, preferenceRequest(handler, "GET", "", cookie), "dark")
	second := preferenceRequest(handler, "GET", "", nil)
	savedTheme(t, second, "light")
	if second.Result().Cookies()[0].Value == cookie.Value {
		t.Fatal("sessions must be independent")
	}
	mini.FastForward(20 * 24 * time.Hour)
	renewed := preferenceRequest(handler, "GET", "", cookie)
	savedTheme(t, renewed, "dark")
	if mini.TTL("session:"+cookie.Value) != sessionLifetime {
		t.Fatal("TTL not renewed")
	}
	if renewed.Result().Cookies()[0].MaxAge != cookie.MaxAge {
		t.Fatal("cookie lifetime not renewed")
	}
	mini.FastForward(sessionLifetime + time.Second)
	savedTheme(t, preferenceRequest(handler, "GET", "", cookie), "light")
	invalid := preferenceRequest(handler, "GET", "", &http.Cookie{Name: "weather_session", Value: "../../invalid"})
	savedTheme(t, invalid, "light")
	if !sessionPattern.MatchString(invalid.Result().Cookies()[0].Value) {
		t.Fatal("invalid ID not replaced")
	}
}
func TestPreferencesInvalidInputAndRedisUnavailable(t *testing.T) {
	mini := miniredis.RunT(t)
	client := newRedisClient(Config{RedisAddr: mini.Addr()})
	defer client.Close()
	handler := newHandler(&memoryStore{}, nil, "", &preferenceHandler{client: client})
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
	mini.Close()
	for _, method := range []string{"GET", "PUT"} {
		start := time.Now()
		response := preferenceRequest(handler, method, `{"theme":"dark"}`, cookie)
		if response.Code != 503 || len(response.Result().Cookies()) != 0 {
			t.Fatalf("Redis unavailable: %d", response.Code)
		}
		if time.Since(start) > 3*time.Second {
			t.Fatal("Redis operation timeout exceeded")
		}
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest("GET", "/api/history", nil))
	if response.Code != 200 {
		t.Fatal("Redis failure must not break weather reads")
	}
	if preferenceRequest(handler, "DELETE", "", cookie).Code != 405 {
		t.Fatal("unsupported method accepted")
	}
}
func TestPreferencesConcurrentReadDoesNotOverwrite(t *testing.T) {
	mini := miniredis.RunT(t)
	client := newRedisClient(Config{RedisAddr: mini.Addr()})
	defer client.Close()
	handler := &preferenceHandler{client: client}
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
}
