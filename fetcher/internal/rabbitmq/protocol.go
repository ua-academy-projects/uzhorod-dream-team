package rabbitmq

import (
	"encoding/json"
	"time"
)

const Version = 1

const (
	ListLocations        = "locations.list"
	LatestLocations      = "locations.latest"
	LocationMeasurements = "locations.measurements"
)

type Request struct {
	Version    int       `json:"version"`
	Operation  string    `json:"operation"`
	LocationID int       `json:"location_id,omitempty"`
	From       string    `json:"from,omitempty"`
	To         string    `json:"to,omitempty"`
	Deadline   time.Time `json:"deadline"`
}

type Response struct {
	Version int             `json:"version"`
	Data    json.RawMessage `json:"data,omitempty"`
	Error   string          `json:"error,omitempty"`
}
