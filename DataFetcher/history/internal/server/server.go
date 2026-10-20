package server

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"
	

	"data-monitor/history/internal/database"
)

type API struct{ DB *database.Store }

func (a API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		respond(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /history", a.history)
	mux.HandleFunc("GET /sources", a.sources)
	mux.HandleFunc("GET /preferences/{sessionID}", a.getPreferences)
	mux.HandleFunc("PUT /preferences/{sessionID}", a.putPreferences)
	return mux
}

func (a API) sources(w http.ResponseWriter, r *http.Request) {
	names, err := a.DB.Sources(r.Context())
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{
			"error": "failed to read sources",
		})
		return
	}
	respond(w, http.StatusOK, map[string]any{"data": names})
}

func (a API) history(w http.ResponseWriter, r *http.Request) {
	source := r.URL.Query().Get("source")
	if source == "" {
		source = "btc"
	}

	limit := 100
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 {
			respond(w, http.StatusBadRequest, map[string]string{
				"error": "limit must be between 1 and 1000",
			})
			return
		}
		limit = parsed
	}
	if limit > 1000 {
		limit = 1000
	}

	from, err := parseTime(r.URL.Query().Get("from"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{
			"error": "invalid from timestamp",
		})
		return
	}
	to, err := parseTime(r.URL.Query().Get("to"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{
			"error": "invalid to timestamp",
		})
		return
	}

	data, err := a.DB.List(r.Context(), source, limit, from, to)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{
			"error": "failed to read history",
		})
		return
	}
	respond(w, http.StatusOK, map[string]any{"data": data})
}

func (a API) getPreferences(w http.ResponseWriter, r *http.Request) {
    sessionID := r.PathValue("sessionID")
    if sessionID == "" || len(sessionID) > 100 {
        respond(w, http.StatusBadRequest, map[string]string{
            "error": "invalid session ID",
        })
        return
    }

    preferences, found, err := a.DB.GetPreferences(r.Context(), sessionID)
    if err != nil {
        respond(w, http.StatusInternalServerError, map[string]string{
            "error": "failed to read preferences",
        })
        return
    }

    if !found {
        respond(w, http.StatusNotFound, map[string]string{
            "error": "preferences not found",
        })
        return
    }

    respond(w, http.StatusOK, map[string]any{
        "preferences": preferences,
    })
}

func (a API) putPreferences(w http.ResponseWriter, r *http.Request) {
    sessionID := r.PathValue("sessionID")
    if sessionID == "" || len(sessionID) > 100 {
        respond(w, http.StatusBadRequest, map[string]string{
            "error": "invalid session ID",
        })
        return
    }

    var body struct {
        Preferences map[string]string `json:"preferences"`
    }

    if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
        respond(w, http.StatusBadRequest, map[string]string{
            "error": "invalid JSON",
        })
        return
    }

    if err := a.DB.SavePreferences(
        r.Context(),
        sessionID,
        body.Preferences,
    ); err != nil {
        respond(w, http.StatusInternalServerError, map[string]string{
            "error": "failed to save preferences",
        })
        return
    }

    respond(w, http.StatusOK, map[string]any{
        "preferences": body.Preferences,
    })
}


func parseTime(raw string) (*time.Time, error) {
	if raw == "" {
		return nil, nil
	}
	parsed, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return nil, err
	}
	utc := parsed.UTC()
	return &utc, nil
}

func respond(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
