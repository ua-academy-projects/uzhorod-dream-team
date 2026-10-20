package settings

import (
	"context"
	"encoding/json"
	"fmt"
	"history/internal/model"

	"github.com/redis/go-redis/v9"
)

type RedisRepository struct {
	redis *redis.Client
}

func NewRedisRepository(
	redis *redis.Client,
) Repository {
	return &RedisRepository{
		redis: redis,
	}
}

func (r *RedisRepository) GetSettings(
	ctx context.Context,
	id string,
) (*model.Settings, error) {
	key := fmt.Sprintf("settings:%s", id)

	value, err := r.redis.Get(ctx, key).Result()

	if err == redis.Nil {
		settings := model.Settings{
			Theme: model.ThemeAuto,
		}

		if err := r.SetSettings(ctx, id, settings); err != nil {
			return nil, err
		}

		return &settings, nil
	}

	if err != nil {
		return nil, err
	}

	var settings model.Settings

	if err := json.Unmarshal([]byte(value), &settings); err != nil {
		return nil, err
	}

	return &settings, nil
}

func (r *RedisRepository) SetSettings(
	ctx context.Context,
	id string,
	settings model.Settings,
) error {
	key := "settings:" + id

	value, err := json.Marshal(settings)
	if err != nil {
		return err
	}

	return r.redis.Set(ctx, key, value, 0).Err()
}
