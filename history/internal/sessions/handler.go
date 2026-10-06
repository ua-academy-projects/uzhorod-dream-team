package sessions

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"mime"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"history/internal/httpjson"
)

const CookieName = "kyiv_air_session"

type HandlerOptions struct {
	TTL     time.Duration
	Timeout time.Duration
	Secure  bool
	Now     func() time.Time
}

type Handler struct {
	service Service
	options HandlerOptions
}

func NewHandler(service Service, options HandlerOptions) *Handler {
	if options.Now == nil {
		options.Now = time.Now
	}
	return &Handler{service: service, options: options}
}

func (h *Handler) RegisterRoutes(r chi.Router, writeMiddleware func(http.Handler) http.Handler) {
	r.Get("/session", h.Get)
	r.With(writeMiddleware).Put("/session", h.Update)
}

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	ctx, cancel := context.WithTimeout(r.Context(), h.options.Timeout)
	defer cancel()
	id, preferences, err := h.service.Get(ctx, sessionID(r))
	h.respond(w, id, preferences, err)
}

func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		httpjson.Error(w, http.StatusUnsupportedMediaType, "application/json required")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	var preferences Preferences
	if err := decoder.Decode(&preferences); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "invalid preferences")
		return
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		httpjson.Error(w, http.StatusBadRequest, "expected a single preference snapshot")
		return
	}
	if err := preferences.Validate(); err != nil {
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), h.options.Timeout)
	defer cancel()
	id, saved, err := h.service.Update(ctx, sessionID(r), preferences)
	h.respond(w, id, saved, err)
}

func sessionID(r *http.Request) string {
	if cookie, err := r.Cookie(CookieName); err == nil {
		return cookie.Value
	}
	return ""
}

func (h *Handler) respond(w http.ResponseWriter, id string, preferences Preferences, err error) {
	if err != nil {
		log.Print("Session store unavailable")
		httpjson.Error(w, http.StatusServiceUnavailable, "selections cannot currently be saved")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name: CookieName, Value: id, Path: "/api/v1", HttpOnly: true,
		SameSite: http.SameSiteLaxMode, Secure: h.options.Secure,
		MaxAge: int(h.options.TTL.Seconds()), Expires: h.options.Now().Add(h.options.TTL),
	})
	httpjson.Write(w, http.StatusOK, preferences)
}
