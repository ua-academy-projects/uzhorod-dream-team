package locations

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"
)

type Handler struct {
	service Service
}

func NewHandler(service Service) *Handler {
	return &Handler{
		service: service,
	}
}

func (h *Handler) RegisterRoutes(r chi.Router) {
	r.Get("/locations", h.GetLocations)
	r.Get("/locations/latest", h.GetLocationsLatest)
	r.Get("/locations/{id}/measurements", h.GetLocationMeasurements)
}

func (h *Handler) GetLocations(w http.ResponseWriter, r *http.Request) {
	locs, err := h.service.GetLocations(r.Context())
	if err != nil {
		h.errorResponse(w, http.StatusInternalServerError, err.Error())
		return
	}
	h.jsonResponse(w, http.StatusOK, locs)
}

func (h *Handler) GetLocationsLatest(w http.ResponseWriter, r *http.Request) {
	locations, err := h.service.GetLocationsLatest(r.Context())
	if err != nil {
		h.errorResponse(w, http.StatusInternalServerError, err.Error())
		return
	}

	h.jsonResponse(w, http.StatusOK, locations)
}

func (h *Handler) GetLocationMeasurements(w http.ResponseWriter, r *http.Request) {
	idStr := chi.URLParam(r, "id")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		h.errorResponse(w, http.StatusBadRequest, "invalid location ID")
		return
	}

	from := r.URL.Query().Get("from")
	to := r.URL.Query().Get("to")

	measurements, err := h.service.GetLocationMeasurements(r.Context(), id, from, to)
	if err != nil {
		h.errorResponse(w, http.StatusInternalServerError, err.Error())
		return
	}

	if measurements == nil {
		measurements = []Measurement{}
	}

	h.jsonResponse(w, http.StatusOK, measurements)
}

func (h *Handler) jsonResponse(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func (h *Handler) errorResponse(w http.ResponseWriter, status int, message string) {
	h.jsonResponse(w, status, map[string]string{"error": message})
}
