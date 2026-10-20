package models

import "time"

type Current struct {
	Value     float64   `json:"value"`
	Source    string    `json:"source"`
	Timestamp time.Time `json:"timestamp"`
}
type Record struct {
	ID         int64     `json:"id"`
	Source     string    `json:"source"`
	Value      float64   `json:"value"`
	RecordedAt time.Time `json:"recorded_at"`
}
