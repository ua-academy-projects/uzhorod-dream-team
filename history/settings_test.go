package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// memorySettings is a fake store: a map instead of Redis.
type memorySettings struct {
	values map[string]Settings
	err    error // if set, every call fails, as if Redis were down
}

func newMemorySettings() *memorySettings {
	return &memorySettings{values: map[string]Settings{}}
}

func (m *memorySettings) load(_ context.Context, sessionID string) (Settings, bool, error) {
	if m.err != nil {
		return Settings{}, false, m.err
	}
	settings, found := m.values[sessionID]
	return settings, found, nil
}

func (m *memorySettings) save(_ context.Context, sessionID string, settings Settings) error {
	if m.err != nil {
		return m.err
	}
	m.values[sessionID] = settings
	return nil
}

const knownSessionID = "ABCDEFGHIJKLMNOPQRSTUVWXYZ" // 26 characters A-Z

func settingsRequest(method, body, sessionID string) *http.Request {
	request := httptest.NewRequest(method, "/api/settings", strings.NewReader(body))
	if sessionID != "" {
		request.AddCookie(&http.Cookie{Name: sessionCookie, Value: sessionID})
	}
	return request
}

func responseSettings(t *testing.T, response *httptest.ResponseRecorder) Settings {
	t.Helper()
	var settings Settings
	if err := json.Unmarshal(response.Body.Bytes(), &settings); err != nil {
		t.Fatalf("не вдалося прочитати JSON: %v", err)
	}
	return settings
}

func responseCookie(t *testing.T, response *httptest.ResponseRecorder) *http.Cookie {
	t.Helper()
	for _, cookie := range response.Result().Cookies() {
		if cookie.Name == sessionCookie {
			return cookie
		}
	}
	t.Fatal("відповідь без cookie сесії")
	return nil
}

func TestSettingsGetWithoutCookieGivesDefaultsAndNewCookie(t *testing.T) {
	response := httptest.NewRecorder()

	settingsHandler(newMemorySettings()).ServeHTTP(response, settingsRequest(http.MethodGet, "", ""))

	if response.Code != http.StatusOK {
		t.Fatalf("статус = %d, очікувався %d", response.Code, http.StatusOK)
	}
	if got := responseSettings(t, response); got != defaultSettings {
		t.Fatalf("налаштування = %#v, очікувалися типові", got)
	}
	cookie := responseCookie(t, response)
	if !sessionIDPattern.MatchString(cookie.Value) {
		t.Errorf("id сесії %q має неправильний формат", cookie.Value)
	}
	if !cookie.HttpOnly || cookie.SameSite != http.SameSiteLaxMode || cookie.MaxAge != 30*24*60*60 {
		t.Errorf("cookie = %+v, очікувалися HttpOnly, SameSite=Lax і 30 днів", cookie)
	}
}

func TestSettingsPutSavesAndGetReturnsThem(t *testing.T) {
	store := newMemorySettings()
	handler := settingsHandler(store)

	put := httptest.NewRecorder()
	handler.ServeHTTP(put, settingsRequest(http.MethodPut, `{"theme": "dark", "lang": "en"}`, knownSessionID))
	if put.Code != http.StatusOK {
		t.Fatalf("PUT: статус = %d, очікувався %d", put.Code, http.StatusOK)
	}
	if saved := store.values[knownSessionID]; saved != (Settings{Theme: "dark", Lang: "en"}) {
		t.Fatalf("у сховищі %#v, очікувалися темна тема й англійська", saved)
	}

	// The same browser (the same cookie) opens the page again.
	get := httptest.NewRecorder()
	handler.ServeHTTP(get, settingsRequest(http.MethodGet, "", knownSessionID))
	if got := responseSettings(t, get); got != (Settings{Theme: "dark", Lang: "en"}) {
		t.Fatalf("GET: налаштування = %#v, очікувалися dark і en", got)
	}
	if cookie := responseCookie(t, get); cookie.Value != knownSessionID {
		t.Errorf("id сесії змінився: %q", cookie.Value)
	}
}

func TestSettingsAnotherBrowserGetsOwnSettings(t *testing.T) {
	store := newMemorySettings()
	store.values[knownSessionID] = Settings{Theme: "dark", Lang: "en"}
	response := httptest.NewRecorder()

	// Another browser has no cookie yet.
	settingsHandler(store).ServeHTTP(response, settingsRequest(http.MethodGet, "", ""))

	if got := responseSettings(t, response); got != defaultSettings {
		t.Fatalf("налаштування = %#v, очікувалися типові", got)
	}
	if cookie := responseCookie(t, response); cookie.Value == knownSessionID {
		t.Error("інший браузер отримав чужу сесію")
	}
}

func TestSettingsPutRejectsWrongValues(t *testing.T) {
	bodies := []string{
		`{"theme": "pink", "lang": "uk"}`,
		`{"theme": "dark", "lang": "de"}`,
		`{"theme": "dark"}`,
		`{"theme": "dark", "lang": "uk", "admin": true}`,
		`не JSON`,
		`{"theme": "` + strings.Repeat("x", 2000) + `"}`,
	}
	for _, body := range bodies {
		store := newMemorySettings()
		response := httptest.NewRecorder()

		settingsHandler(store).ServeHTTP(response, settingsRequest(http.MethodPut, body, knownSessionID))

		if response.Code != http.StatusBadRequest {
			t.Errorf("тіло %.30q: статус = %d, очікувався %d", body, response.Code, http.StatusBadRequest)
		}
		if len(store.values) != 0 {
			t.Errorf("тіло %.30q: некоректні налаштування збережено", body)
		}
	}
}

func TestSettingsIgnoresForeignCookieValue(t *testing.T) {
	store := newMemorySettings()
	response := httptest.NewRecorder()

	settingsHandler(store).ServeHTTP(response,
		settingsRequest(http.MethodPut, `{"theme": "dark", "lang": "en"}`, "../../etc/passwd"))

	if cookie := responseCookie(t, response); !sessionIDPattern.MatchString(cookie.Value) {
		t.Fatalf("сервер прийняв чужий id сесії %q", cookie.Value)
	}
	if _, found := store.values["../../etc/passwd"]; found {
		t.Fatal("налаштування збережено під чужим id")
	}
}

func TestSettingsUnavailableWhenStoreFails(t *testing.T) {
	store := newMemorySettings()
	store.err = errors.New("redis недоступний")

	for _, method := range []string{http.MethodGet, http.MethodPut} {
		response := httptest.NewRecorder()
		settingsHandler(store).ServeHTTP(response, settingsRequest(method, `{"theme": "dark", "lang": "en"}`, knownSessionID))

		if response.Code != http.StatusServiceUnavailable {
			t.Errorf("%s: статус = %d, очікувався %d", method, response.Code, http.StatusServiceUnavailable)
		}
	}
}

func TestSettingsRejectsOtherMethods(t *testing.T) {
	response := httptest.NewRecorder()

	settingsHandler(newMemorySettings()).ServeHTTP(response, settingsRequest(http.MethodPost, "", ""))

	if response.Code != http.StatusMethodNotAllowed {
		t.Fatalf("статус = %d, очікувався %d", response.Code, http.StatusMethodNotAllowed)
	}
	if got := response.Header().Get("Allow"); got != "GET, PUT" {
		t.Fatalf("Allow = %q, очікувався \"GET, PUT\"", got)
	}
}

func TestDecodeSavedGivesOldRecordsTheDefaultLanguage(t *testing.T) {
	// Saved before the language setting existed: only the theme.
	settings, ok := decodeSaved([]byte(`{"theme": "dark"}`))

	if !ok || settings != (Settings{Theme: "dark", Lang: "uk"}) {
		t.Fatalf("налаштування = %#v (ok=%v), очікувалися dark і uk", settings, ok)
	}
}

func TestDecodeSavedRejectsBrokenRecords(t *testing.T) {
	for _, value := range []string{`не JSON`, `{"theme": "pink"}`, `{"theme": "dark", "lang": "de"}`} {
		if _, ok := decodeSaved([]byte(value)); ok {
			t.Errorf("запис %q прийнято, хоча він некоректний", value)
		}
	}
}
