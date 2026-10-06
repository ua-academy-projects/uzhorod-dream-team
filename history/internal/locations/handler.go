package locations

import (
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"history/internal/httpjson"
	"history/internal/measurements"
	"history/internal/parameters"
)

type Handler struct {
	service Service
}

func NewHandler(service Service) *Handler {
	return &Handler{service: service}
}

func (h *Handler) RegisterRoutes(r chi.Router) {
	r.Get("/locations", h.GetLocations)
	r.Get("/locations/{id}/parameters", h.GetLocationParameters)
	r.Get("/locations/{id}/history", h.GetLocationHistory)
}

func (h *Handler) GetLocations(w http.ResponseWriter, r *http.Request) {
	locs, err := h.service.GetLocations(r.Context())
	if err != nil {
		log.Printf("DB error in GetLocations: %v", err)
		httpjson.Error(w, http.StatusInternalServerError, "Internal Server Error")
		return
	}
	httpjson.Write(w, http.StatusOK, locs)
}

func (h *Handler) GetLocationParameters(w http.ResponseWriter, r *http.Request) {
	idStr := chi.URLParam(r, "id")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, "invalid location ID")
		return
	}

	params, err := h.service.GetLocationParameters(r.Context(), id)
	if err != nil {
		log.Printf("DB error in GetLocationParameters: %v", err)
		httpjson.Error(w, http.StatusInternalServerError, "Internal Server Error")
		return
	}
	if params == nil {
		params = []parameters.Parameter{}
	}
	httpjson.Write(w, http.StatusOK, params)
}

func (h *Handler) GetLocationHistory(w http.ResponseWriter, r *http.Request) {
	idStr := chi.URLParam(r, "id")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, "invalid location ID")
		return
	}

	param := r.URL.Query().Get("parameter")
	if param == "" {
		httpjson.Error(w, http.StatusBadRequest, "parameter query arg is required")
		return
	}

	fromStr := r.URL.Query().Get("from")
	toStr := r.URL.Query().Get("to")

	var from, to time.Time

	if toStr != "" {
		to, err = time.Parse(time.RFC3339, toStr)
		if err != nil {
			httpjson.Error(w, http.StatusBadRequest, "invalid 'to' date format, expected RFC3339")
			return
		}
	} else {
		to = time.Now()
	}

	if fromStr != "" {
		from, err = time.Parse(time.RFC3339, fromStr)
		if err != nil {
			httpjson.Error(w, http.StatusBadRequest, "invalid 'from' date format, expected RFC3339")
			return
		}
	} else {
		from = to.Add(-24 * time.Hour)
	}

	historyData, err := h.service.GetLocationHistory(r.Context(), id, param, from, to)
	if err != nil {
		log.Printf("DB error in GetLocationHistory: %v", err)
		httpjson.Error(w, http.StatusInternalServerError, "Internal Server Error")
		return
	}

	if historyData == nil {
		historyData = []measurements.MeasurementData{}
	}

	httpjson.Write(w, http.StatusOK, historyData)
}
