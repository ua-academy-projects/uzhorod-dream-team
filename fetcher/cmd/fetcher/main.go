package main

import (
	"log"
	"net/http"

	"fetcher/internal/config"
	"fetcher/internal/locations"
	"fetcher/internal/openaq"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

func main() {
	cfg := config.Load()
	aqClient := openaq.NewClient(cfg)
	locService := locations.NewService(aqClient)
	locHandler := locations.NewHandler(locService)

	r := chi.NewRouter()
	r.Use(middleware.Heartbeat("/health"))
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	r.Route("/api/v1", func(r chi.Router) {
		locHandler.RegisterRoutes(r)
	})

	log.Printf("Starting Fetcher Service on port %s", cfg.Port)
	if err := http.ListenAndServe(":"+cfg.Port, r); err != nil {
		log.Fatalf("Server failed to start: %v", err)
	}
}
