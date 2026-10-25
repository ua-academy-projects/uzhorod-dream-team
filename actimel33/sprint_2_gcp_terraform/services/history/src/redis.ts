import { createClient } from 'redis';
import type { RedisClientType } from 'redis';
import { config } from './config.ts';

let shared: RedisClientType | null = null;

async function connect(name: string): Promise<RedisClientType> {
  const client: RedisClientType = createClient({ url: config.redisUrl, password: config.redisPassword });
  client.on('error', (err: Error) => {
    console.error(`[history] redis ${name} error: ${err.message}`);
  });
  await client.connect();
  return client;
}

/** One shared connection for sessions and publishing, opened on first use. */
export async function redis(): Promise<RedisClientType> {
  if (shared?.isOpen) return shared;
  shared = await connect('client');
  return shared;
}

/**
 * A connection of its own for XREADGROUP BLOCK: commands on one connection run
 * in order, so a blocking read would stall every session lookup behind it.
 */
export const blockingRedis = (): Promise<RedisClientType> => connect('reader');
