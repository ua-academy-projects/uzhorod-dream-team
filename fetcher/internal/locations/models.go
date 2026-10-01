package locations

type Location struct {
	ID     int           `json:"id"`
	Name   string        `json:"name"`
	Lat    float64       `json:"lat"`
	Lon    float64       `json:"lon"`
	Latest []Measurement `json:"latest,omitempty"`
}

type Measurement struct {
	Parameter string  `json:"parameter"`
	Value     float64 `json:"value"`
	Unit      string  `json:"unit"`
	Timestamp string  `json:"timestamp"`
}
