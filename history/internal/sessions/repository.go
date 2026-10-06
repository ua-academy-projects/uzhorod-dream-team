package sessions

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/redis/go-redis/v9"
)

type Repository interface {
	Load(context.Context, string, time.Duration) (Preferences, error)
	Save(context.Context, string, Preferences, time.Duration) error
}

type redisRepository struct {
	client redis.Cmdable
}

func NewRepository(client redis.Cmdable) Repository {
	return &redisRepository{client: client}
}

func (r *redisRepository) Load(ctx context.Context, id string, ttl time.Duration) (Preferences, error) {
	data, err := r.client.GetEx(ctx, "kyiv-air:session:"+id, ttl).Bytes()
	if errors.Is(err, redis.Nil) {
		return Preferences{}, ErrNotFound
	}
	if err != nil {
		return Preferences{}, err
	}
	var preferences Preferences
	if err := json.Unmarshal(data, &preferences); err != nil {
		return Preferences{}, err
	}
	if err := preferences.Validate(); err != nil {
		return Preferences{}, err
	}
	return preferences, nil
}

func (r *redisRepository) Save(ctx context.Context, id string, preferences Preferences, ttl time.Duration) error {
	data, err := json.Marshal(preferences)
	if err != nil {
		return err
	}
	return r.client.Set(ctx, "kyiv-air:session:"+id, data, ttl).Err()
}
