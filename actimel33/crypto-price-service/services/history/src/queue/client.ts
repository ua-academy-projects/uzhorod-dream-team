import { createClient } from 'redis';
import type { RedisClientType } from 'redis';
import { config } from '../config.ts';

/**
 * Streams carrying the conversation with the fetcher. Requests travel one way,
 * results the other; neither service knows the other's address any more.
 */
export const STREAM_REQUESTS = 'price:requests';
export const STREAM_RESULTS = 'price:results';
export const GROUP_HISTORY = 'history';
export const MAX_STREAM_LEN = 1000;

let client: RedisClientType | null = null;

/** One shared connection, opened on first use. */
export async function redis(): Promise<RedisClientType> {
  if (client?.isOpen) return client;

  client = createClient({ url: config.redisUrl, password: config.redisPassword });
  client.on('error', (err: Error) => {
    console.error(`[history] redis error: ${err.message}`);
  });
  await client.connect();
  return client;
}

export async function closeRedis(): Promise<void> {
  if (client?.isOpen) await client.quit();
  client = null;
}

/** Creates the consumer group, tolerating the one that already exists. */
export async function ensureGroup(stream: string, group: string): Promise<void> {
  const connection = await redis();
  try {
    await connection.xGroupCreate(stream, group, '0', { MKSTREAM: true });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    if (!message.includes('BUSYGROUP')) throw err;
  }
}
