package domain

import (
	"context"
	"regexp"
	"time"
)

const SessionLifetime = 30 * 24 * time.Hour

var SessionPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type Preferences struct {
	Theme string `json:"theme"`
}

type PreferenceStore interface {
	GetPreferences(context.Context, string) (Preferences, error)
	SetPreferences(context.Context, string, Preferences) error
}
