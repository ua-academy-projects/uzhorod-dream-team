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
)

const sessionLifetime = 30 * 24 * time.Hour

var sessionPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type Preferences struct {
	Theme string `json:"theme"`
}

type preferenceStore interface {
	GetPreferences(context.Context, string) (Preferences, error)
	SetPreferences(context.Context, string, Preferences) error
}

type preferenceHandler struct {
	store  preferenceStore
	secure bool
}

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
	if p == nil || p.store == nil {
		writeError(w, 503, "Theme settings are unavailable")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if r.Method == http.MethodPut {
		if err := p.store.SetPreferences(ctx, id, preferences); err != nil {
			writeError(w, 503, "Could not save theme settings")
			return
		}
	} else {
		var err error
		preferences, err = p.store.GetPreferences(ctx, id)
		if err != nil || (preferences.Theme != "light" && preferences.Theme != "dark") {
			writeError(w, 503, "Could not load theme settings")
			return
		}
	}
	http.SetCookie(w, &http.Cookie{Name: "weather_session", Value: id, Path: "/", HttpOnly: true,
		SameSite: http.SameSiteLaxMode, Secure: p.secure, MaxAge: int(sessionLifetime / time.Second), Expires: time.Now().UTC().Add(sessionLifetime)})
	writeJSON(w, 200, preferences)
}
