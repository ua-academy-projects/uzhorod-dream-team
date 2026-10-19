package redis

import (
	"context"
	"encoding/json"
	"time"

	"github.com/redis/go-redis/v9"

	"weather-history/internal/config"
	"weather-history/internal/domain"
)

type Store struct {
	client *redis.Client
}

func New(client *redis.Client) *Store {
	return &Store{client: client}
}

func NewClient(cfg config.Config) *redis.Client {
	return redis.NewClient(&redis.Options{
		Addr: cfg.RedisAddr, Password: cfg.RedisPassword,
		DialTimeout: time.Second, ReadTimeout: time.Second, WriteTimeout: time.Second,
		PoolTimeout: time.Second, MaxRetries: -1, ContextTimeoutEnabled: true,
	})
}

// Read and renew atomically: a GET must never overwrite a concurrent PUT.
var readPreferences = redis.NewScript(`
local value = redis.call('GET', KEYS[1])
if not value then
 value = '{"theme":"light"}'
 redis.call('SET', KEYS[1], value, 'EX', ARGV[1])
else
 redis.call('EXPIRE', KEYS[1], ARGV[1])
end
return value
`)

func (s *Store) GetPreferences(ctx context.Context, id string) (domain.Preferences, error) {
	var preferences domain.Preferences
	data, err := readPreferences.Run(ctx, s.client, []string{"session:" + id}, int(domain.SessionLifetime/time.Second)).Text()
	if err != nil {
		return preferences, err
	}
	err = json.Unmarshal([]byte(data), &preferences)
	return preferences, err
}

func (s *Store) SetPreferences(ctx context.Context, id string, preferences domain.Preferences) error {
	data, err := json.Marshal(preferences)
	if err != nil {
		return err
	}
	return s.client.Set(ctx, "session:"+id, data, domain.SessionLifetime).Err()
}
