package main

import (
	"context"
	"encoding/json"
	"time"

	"github.com/redis/go-redis/v9"
)

type redisPreferences struct {
	client *redis.Client
}

func newRedisClient(config Config) *redis.Client {
	return redis.NewClient(&redis.Options{
		Addr: config.RedisAddr, Password: config.RedisPassword,
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

func (s *redisPreferences) GetPreferences(ctx context.Context, id string) (Preferences, error) {
	var preferences Preferences
	data, err := readPreferences.Run(ctx, s.client, []string{"session:" + id}, int(sessionLifetime/time.Second)).Text()
	if err != nil {
		return preferences, err
	}
	err = json.Unmarshal([]byte(data), &preferences)
	return preferences, err
}

func (s *redisPreferences) SetPreferences(ctx context.Context, id string, preferences Preferences) error {
	data, err := json.Marshal(preferences)
	if err != nil {
		return err
	}
	return s.client.Set(ctx, "session:"+id, data, sessionLifetime).Err()
}
