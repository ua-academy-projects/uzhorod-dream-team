package locations

import "time"

type Location struct {
	ID           int        `json:"id"`
	Name         string     `json:"name"`
	Lat          float64    `json:"lat"`
	Lon          float64    `json:"lon"`
	LastSyncTime *time.Time `json:"last_sync_time,omitempty"`
}
