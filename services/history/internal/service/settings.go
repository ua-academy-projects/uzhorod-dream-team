package service

import (
	"context"
	"history/internal/model"
	"history/internal/repository/settings"
)

type SettingsService struct {
	repo      settings.Repository
	cacheType model.CacheType
}

func NewSettingsService(
	repo settings.Repository,
	cacheType model.CacheType,
) *SettingsService {
	return &SettingsService{
		repo:      repo,
		cacheType: cacheType,
	}
}

func (s *SettingsService) GetSettings(
	ctx context.Context,
	id string,
) (*model.Settings, error) {
	return s.repo.GetSettings(ctx, id)
}

func (s *SettingsService) SetSettings(
	ctx context.Context,
	id string,
	settings model.Settings,
) error {
	return s.repo.SetSettings(ctx, id, settings)
}
