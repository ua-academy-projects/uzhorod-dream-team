package openaq

type LocationResult struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	Coordinates struct {
		Lat float64 `json:"latitude"`
		Lon float64 `json:"longitude"`
	} `json:"coordinates"`
	Sensors []SensorResult `json:"sensors"`
}

type LocationsResponse struct {
	Results []LocationResult `json:"results"`
}

type SensorResult struct {
	ID        int    `json:"id"`
	Name      string `json:"name"`
	Parameter struct {
		ID          int    `json:"id"`
		Name        string `json:"name"`
		Units       string `json:"units"`
		DisplayName string `json:"displayName"`
	} `json:"parameter"`
}

type SensorsResponse struct {
	Results []SensorResult `json:"results"`
}

type MeasurementResult struct {
	Value       float64 `json:"value"`
	Period      Period  `json:"period"`
	Coordinates struct {
		Lat float64 `json:"latitude"`
		Lon float64 `json:"longitude"`
	} `json:"coordinates"`
}

type DatetimeObj struct {
	UTC   string `json:"utc"`
	Local string `json:"local"`
}

type Period struct {
	Label        string      `json:"label"`
	Interval     string      `json:"interval"`
	DatetimeFrom DatetimeObj `json:"datetimeFrom"`
	DatetimeTo   DatetimeObj `json:"datetimeTo"`
}

type MeasurementsResponse struct {
	Results []MeasurementResult `json:"results"`
}

type LatestResult struct {
	SensorsID int     `json:"sensorsId"`
	Value     float64 `json:"value"`
	Datetime  struct {
		UTC   string `json:"utc"`
		Local string `json:"local"`
	} `json:"datetime"`
}

type LocationsLatestResponse struct {
	Results []LatestResult `json:"results"`
}
