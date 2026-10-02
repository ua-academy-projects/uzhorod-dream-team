package measurements

import "time"

type Measurement struct {
	LocationID  int
	ParameterID int
	Value       float64
	Timestamp   time.Time
}

type MeasurementData struct {
	Value     float64   `json:"value"`
	Timestamp time.Time `json:"timestamp"`
}
