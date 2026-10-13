package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"time"

	"github.com/redis/go-redis/v9"
)

const sessionLifetime = 30 * 24 * time.Hour

var sessionPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type Preferences struct {
	Theme string `json:"theme"`
}
type preferenceHandler struct {
	client *redis.Client
	secure bool
}

func newRedisClient(config Config) *redis.Client {
	return redis.NewClient(&redis.Options{
		Addr: config.RedisAddr, Password: config.RedisPassword,
		DialTimeout: time.Second, ReadTimeout: time.Second, WriteTimeout: time.Second,
		PoolTimeout: time.Second, MaxRetries: -1, ContextTimeoutEnabled: true,
	})
}

// Read and renew atomically: a GET must never overwrite a concurrent PUT.
var readPreferences = redis.NewScript(`
local value = redis.call('GET', KEYS[1])
if not value then
 value = '{"theme":"light"}'
 redis.call('SET', KEYS[1], value, 'EX', ARGV[1])
else
 redis.call('EXPIRE', KEYS[1], ARGV[1])
end
return value
`)

func (p *preferenceHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPut && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD, PUT")
		writeError(w, 405, "Use GET or PUT")
		return
	}
	preferences := Preferences{}
	if r.Method == http.MethodPut {
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&preferences); err != nil {
			writeError(w, 400, "Expected JSON with theme light or dark")
			return
		}
		var extra any
		if decoder.Decode(&extra) != io.EOF || (preferences.Theme != "light" && preferences.Theme != "dark") {
			writeError(w, 400, "Expected JSON with theme light or dark")
			return
		}
	}
	id := ""
	if cookie, err := r.Cookie("weather_session"); err == nil && sessionPattern.MatchString(cookie.Value) {
		id = cookie.Value
	}
	if id == "" {
		bytes := make([]byte, 32)
		if _, err := rand.Read(bytes); err != nil {
			writeError(w, 503, "Could not create a preferences session")
			return
		}
		id = hex.EncodeToString(bytes)
	}
	if p == nil || p.client == nil {
		writeError(w, 503, "Theme settings are unavailable (Redis)")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	key := "session:" + id
	if r.Method == http.MethodPut {
		data, _ := json.Marshal(preferences)
		if err := p.client.Set(ctx, key, data, sessionLifetime).Err(); err != nil {
			writeError(w, 503, "Could not save theme settings (Redis unavailable)")
			return
		}
	} else {
		data, err := readPreferences.Run(ctx, p.client, []string{key}, int(sessionLifetime/time.Second)).Text()
		if err != nil || json.Unmarshal([]byte(data), &preferences) != nil || (preferences.Theme != "light" && preferences.Theme != "dark") {
			writeError(w, 503, "Could not load theme settings (Redis unavailable)")
			return
		}
	}
	http.SetCookie(w, &http.Cookie{Name: "weather_session", Value: id, Path: "/", HttpOnly: true,
		SameSite: http.SameSiteLaxMode, Secure: p.secure, MaxAge: int(sessionLifetime / time.Second), Expires: time.Now().UTC().Add(sessionLifetime)})
	writeJSON(w, 200, preferences)
}
