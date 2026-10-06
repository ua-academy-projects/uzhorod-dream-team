package sessions

import (
	"errors"
	"strings"
	"time"
)

var ErrNotFound = errors.New("session not found")

type Period struct {
	Kind string `json:"kind"`
	Days int    `json:"days,omitempty"`
	From string `json:"from,omitempty"`
	To   string `json:"to,omitempty"`
}

type Preferences struct {
	LocationID *int    `json:"locationId"`
	Parameter  *string `json:"parameter"`
	Period     Period  `json:"period"`
}

func Defaults() Preferences {
	return Preferences{Period: Period{Kind: "preset", Days: 7}}
}

func (p Preferences) Validate() error {
	if p.LocationID != nil && *p.LocationID <= 0 {
		return errors.New("locationId must be a positive integer or null")
	}
	if p.Parameter != nil && (p.LocationID == nil || len(*p.Parameter) > 128 || strings.TrimSpace(*p.Parameter) == "") {
		return errors.New("parameter requires a location and a nonempty name of at most 128 bytes")
	}
	switch p.Period.Kind {
	case "preset":
		if (p.Period.Days != 1 && p.Period.Days != 7 && p.Period.Days != 30) || p.Period.From != "" || p.Period.To != "" {
			return errors.New("preset period must contain only days equal to 1, 7 or 30")
		}
	case "custom":
		from, fromErr := time.Parse(time.RFC3339Nano, p.Period.From)
		to, toErr := time.Parse(time.RFC3339Nano, p.Period.To)
		if fromErr != nil || toErr != nil || from.After(to) || p.Period.Days != 0 {
			return errors.New("custom period requires ordered RFC3339 from and to timestamps")
		}
	default:
		return errors.New("period kind must be preset or custom")
	}
	return nil
}
