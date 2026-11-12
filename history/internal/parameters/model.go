package parameters

type Parameter struct {
	Name    string `json:"name"`
	Unit    string `json:"unit"`
	HasData bool   `json:"has_data"`
}
