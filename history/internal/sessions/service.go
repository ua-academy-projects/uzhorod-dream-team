package sessions

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"time"
)

type Service interface {
	Get(context.Context, string) (string, Preferences, error)
	Update(context.Context, string, Preferences) (string, Preferences, error)
}

type service struct {
	repository Repository
	ttl        time.Duration
	generateID func() (string, error)
}

func NewService(repository Repository, ttl time.Duration, generateID func() (string, error)) Service {
	if generateID == nil {
		generateID = func() (string, error) {
			var data [32]byte
			if _, err := rand.Read(data[:]); err != nil {
				return "", err
			}
			return base64.RawURLEncoding.EncodeToString(data[:]), nil
		}
	}
	return &service{repository: repository, ttl: ttl, generateID: generateID}
}

func ValidID(id string) bool {
	data, err := base64.RawURLEncoding.DecodeString(id)
	return err == nil && len(data) == 32 && base64.RawURLEncoding.EncodeToString(data) == id
}

func (s *service) Get(ctx context.Context, id string) (string, Preferences, error) {
	if ValidID(id) {
		preferences, err := s.repository.Load(ctx, id, s.ttl)
		if err == nil {
			return id, preferences, nil
		}
		if !errors.Is(err, ErrNotFound) {
			return "", Preferences{}, err
		}
	}
	return s.create(ctx, Defaults())
}

func (s *service) Update(ctx context.Context, id string, preferences Preferences) (string, Preferences, error) {
	if err := preferences.Validate(); err != nil {
		return "", Preferences{}, err
	}
	if ValidID(id) {
		_, err := s.repository.Load(ctx, id, s.ttl)
		if err == nil {
			return id, preferences, s.repository.Save(ctx, id, preferences, s.ttl)
		}
		if !errors.Is(err, ErrNotFound) {
			return "", Preferences{}, err
		}
	}
	return s.create(ctx, preferences)
}

func (s *service) create(ctx context.Context, preferences Preferences) (string, Preferences, error) {
	id, err := s.generateID()
	if err != nil {
		return "", Preferences{}, err
	}
	return id, preferences, s.repository.Save(ctx, id, preferences, s.ttl)
}
