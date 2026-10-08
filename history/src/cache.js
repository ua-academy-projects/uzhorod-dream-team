/**
 * Redis client for small per-browser data (UI preferences).
 * Redis is optional: if it is down the weather API keeps working and callers check `cache.isReady`.
 */
import { createClient } from 'redis';
import config from './config.js';

export const cache = createClient({ url: config.redisUrl });

// The client retries forever while Redis is down; log each distinct error once, not on every retry
let lastError = null;
cache.on('error', (err) => {
  if (err.message === lastError) return;
  lastError = err.message;
  console.error('Redis:', err.message);
});
cache.on('ready', () => {
  lastError = null;
  console.log('Redis connected');
});

export function connectCache() {
  cache.connect().catch((err) => console.error('Redis: cannot connect:', err.message));
}
