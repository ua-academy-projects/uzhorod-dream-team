package httpmiddleware

import (
	"net/http"

	"history/internal/httpjson"
)

func RequireAllowedOrigin(origins []string) func(http.Handler) http.Handler {
	allowed := make(map[string]struct{}, len(origins))
	for _, origin := range origins {
		if origin != "" {
			allowed[origin] = struct{}{}
		}
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if _, ok := allowed[r.Header.Get("Origin")]; !ok {
				w.Header().Set("Cache-Control", "no-store")
				httpjson.Error(w, http.StatusForbidden, "origin not allowed")
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
