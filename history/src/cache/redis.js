/**
 * Redis key-value cache: each value is stored as a JSON string with a TTL.
 * Redis is optional: if it is down the weather API keeps working and callers check `isReady`.
 */
import { createClient } from 'redis';
import config from '../config.js';

let client = null;

export const isReady = () => client?.isReady ?? false;

export function connectCache() {
  client = createClient({ url: config.redisUrl });
  // The client retries forever while Redis is down; log each distinct error once, not on every retry
  let lastError = null;
  client.on('error', (err) => {
    if (err.message === lastError) return;
    lastError = err.message;
    console.error('Redis:', err.message);
  });
  client.on('ready', () => {
    lastError = null;
    console.log('Redis connected');
  });
  client.connect().catch((err) => console.error('Redis: cannot connect:', err.message));
}

export async function get(key) {
  const raw = await client.get(key);
  return raw === null ? null : JSON.parse(raw);
}

export async function set(key, value, ttlSeconds) {
  await client.set(key, JSON.stringify(value), { expiration: { type: 'EX', value: ttlSeconds } });
}
