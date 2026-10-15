/**
 * Key-value cache with TTL for small per-browser data (UI preferences): Redis or a PostgreSQL table
 * (USE_REDIS_RABBITMQ). Values are JSON. The cache is optional: callers check `cache.isReady`.
 */
import config from '../config.js';

// Only the chosen module is loaded, so the other backend needs no configuration
const backend = await import(config.useRedisRabbitMQ ? './redis.js' : './postgres.js');

export const connectCache = () => backend.connectCache();

export const cache = {
  get isReady() {
    return backend.isReady();
  },
  get: (key) => backend.get(key),
  set: (key, value, ttlSeconds) => backend.set(key, value, ttlSeconds),
};
