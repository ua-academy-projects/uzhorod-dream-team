package main

// User settings of the UI (theme and language), kept in Redis (app_mode rabbitmq)
// or in the PostgreSQL table user_settings (app_mode postgres). The two are not synchronized.
// A user is recognized by a random id in a browser cookie, without a login.

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

const (
	sessionCookie = "wh_session"
	// The cookie and the record in Redis live 30 days; every visit extends both.
	settingsTTL = 30 * 24 * time.Hour
)

// rand.Text() gives 26 characters: A-Z and 2-7. Other cookie values are not trusted.
var sessionIDPattern = regexp.MustCompile(`^[A-Z2-7]{26}$`)

// Settings are the user settings. A new setting is a new field here
// plus a check in valid().
type Settings struct {
	Theme string `json:"theme"` // "light" or "dark"
	Lang  string `json:"lang"`  // "uk" or "en"
}

var defaultSettings = Settings{Theme: "light", Lang: "uk"}

func (s Settings) valid() bool {
	return (s.Theme == "light" || s.Theme == "dark") && (s.Lang == "uk" || s.Lang == "en")
}

// decodeSaved reads saved settings (from Redis or PostgreSQL). Records saved before the language
// setting existed have only the theme; they get the default language.
func decodeSaved(value []byte) (Settings, bool) {
	var settings Settings
	if err := json.Unmarshal(value, &settings); err != nil {
		return Settings{}, false
	}
	if settings.Lang == "" {
		settings.Lang = defaultSettings.Lang
	}
	return settings, settings.valid()
}

// settingsStore keeps settings by session id. In the program it is Redis or PostgreSQL,
// in tests a map.
type settingsStore interface {
	// load returns found=false if there are no saved settings for this id.
	load(ctx context.Context, sessionID string) (settings Settings, found bool, err error)
	save(ctx context.Context, sessionID string, settings Settings) error
}

// settingsHandler serves GET and PUT /api/settings.
func settingsHandler(store settingsStore) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sessionID := sessionIDFrom(r)

		var settings Settings
		switch r.Method {
		case http.MethodGet:
			saved, found, err := store.load(r.Context(), sessionID)
			if err != nil {
				settingsUnavailable(w, err)
				return
			}
			settings = defaultSettings
			if found {
				settings = saved
			}

		case http.MethodPut:
			// Settings are tiny: more than 1 KB is not a correct request.
			decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
			decoder.DisallowUnknownFields()
			if err := decoder.Decode(&settings); err != nil || !settings.valid() {
				http.Error(w, `очікується {"theme": "light" або "dark", "lang": "uk" або "en"}`,
					http.StatusBadRequest)
				return
			}
			if err := store.save(r.Context(), sessionID, settings); err != nil {
				settingsUnavailable(w, err)
				return
			}

		default:
			w.Header().Set("Allow", "GET, PUT")
			http.Error(w, "підтримуються лише GET і PUT", http.StatusMethodNotAllowed)
			return
		}

		// The cookie is sent with every answer, so its 30 days start again.
		http.SetCookie(w, &http.Cookie{
			Name:   sessionCookie,
			Value:  sessionID,
			Path:   "/",
			MaxAge: int(settingsTTL.Seconds()),
			// JavaScript cannot read the cookie: only the browser sends it to the server.
			HttpOnly: true,
			// The browser does not send the cookie with PUT requests from other sites.
			SameSite: http.SameSiteLaxMode,
		})
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		if err := json.NewEncoder(w).Encode(settings); err != nil {
			log.Printf("ПОМИЛКА відповіді API налаштувань: %v", err)
		}
	}
}

// sessionIDFrom returns the session id from the cookie, or a new one
// if there is no cookie or its value does not look like our id.
func sessionIDFrom(r *http.Request) string {
	cookie, err := r.Cookie(sessionCookie)
	if err == nil && sessionIDPattern.MatchString(cookie.Value) {
		return cookie.Value
	}
	return rand.Text()
}

// settingsUnavailable answers 503: the settings cannot be read or saved now.
// The UI then uses the default settings; the weather history keeps working.
func settingsUnavailable(w http.ResponseWriter, err error) {
	log.Printf("ПОМИЛКА налаштувань (сховище недоступне): %v", err)
	http.Error(w, "налаштування тимчасово недоступні", http.StatusServiceUnavailable)
}

// connectCache creates a Redis client. Redis is not required for the weather history,
// so if it does not answer now, we only log it: the client connects later by itself.
func connectCache(ctx context.Context, redisURL string) (*redis.Client, error) {
	options, err := redis.ParseURL(redisURL)
	if err != nil {
		return nil, errors.New("неправильний REDIS_URL")
	}
	// Short timeouts: if Redis hangs, the page waits at most a few seconds.
	options.DialTimeout = 2 * time.Second
	options.ReadTimeout = 2 * time.Second
	options.WriteTimeout = 2 * time.Second

	client := redis.NewClient(options)
	if err := client.Ping(ctx).Err(); err != nil {
		log.Printf("ПОПЕРЕДЖЕННЯ: Redis не відповідає (%v) — налаштування недоступні, доки він не запрацює", err)
	} else {
		log.Println("підключено до Redis")
	}
	return client, nil
}

// redisSettings keeps settings in Redis as JSON under the key settings:<session id>.
type redisSettings struct {
	client *redis.Client
}

func settingsKey(sessionID string) string {
	return "settings:" + sessionID
}

func (s redisSettings) load(ctx context.Context, sessionID string) (Settings, bool, error) {
	// GETEX reads the value and at the same time extends its TTL to 30 days.
	value, err := s.client.GetEx(ctx, settingsKey(sessionID), settingsTTL).Bytes()
	if errors.Is(err, redis.Nil) {
		return Settings{}, false, nil
	}
	if err != nil {
		return Settings{}, false, err
	}

	settings, ok := decodeSaved(value)
	if !ok {
		// A broken record: behave as if there were none.
		log.Printf("ПОМИЛКА: некоректні налаштування в Redis — використано типові")
		return Settings{}, false, nil
	}
	return settings, true, nil
}

func (s redisSettings) save(ctx context.Context, sessionID string, settings Settings) error {
	value, err := json.Marshal(settings)
	if err != nil {
		return err
	}
	return s.client.Set(ctx, settingsKey(sessionID), value, settingsTTL).Err()
}

// pgSettings keeps settings in the table user_settings (app_mode postgres):
// one row per session id, the settings as hstore ('theme=>dark, lang=>uk') and the moment
// they expire. The program works with JSON (like in Redis); PostgreSQL converts it:
// hstore_to_json when reading, jsonb_each_text + hstore(keys, values) when saving.
type pgSettings struct {
	db *pgxpool.Pool
}

func (s pgSettings) load(ctx context.Context, sessionID string) (Settings, bool, error) {
	// Like GETEX in Redis: reads the settings and at the same time extends them to 30 days.
	// Expired settings are not returned (as if there were none).
	var value string
	err := s.db.QueryRow(ctx, `
		UPDATE user_settings
		SET expires_at = now() + make_interval(secs => $2)
		WHERE session_id = $1 AND expires_at > now()
		RETURNING hstore_to_json(settings)::text`,
		sessionID, settingsTTL.Seconds(),
	).Scan(&value)
	if errors.Is(err, pgx.ErrNoRows) {
		return Settings{}, false, nil
	}
	if err != nil {
		return Settings{}, false, err
	}

	settings, ok := decodeSaved([]byte(value))
	if !ok {
		// A broken record: behave as if there were none.
		log.Printf("ПОМИЛКА: некоректні налаштування в user_settings — використано типові")
		return Settings{}, false, nil
	}
	return settings, true, nil
}

func (s pgSettings) save(ctx context.Context, sessionID string, settings Settings) error {
	value, err := json.Marshal(settings)
	if err != nil {
		return err
	}
	// A new session gets a new row; an existing one gets the new settings and 30 days again.
	// Every field of Settings becomes one key of hstore, so a new setting needs no new SQL.
	_, err = s.db.Exec(ctx, `
		INSERT INTO user_settings (session_id, settings, expires_at)
		VALUES (
			$1,
			(SELECT hstore(array_agg(key), array_agg(value)) FROM jsonb_each_text($2::jsonb)),
			now() + make_interval(secs => $3))
		ON CONFLICT (session_id) DO UPDATE
		SET settings = EXCLUDED.settings, expires_at = EXCLUDED.expires_at`,
		sessionID, string(value), settingsTTL.Seconds(),
	)
	return err
}
