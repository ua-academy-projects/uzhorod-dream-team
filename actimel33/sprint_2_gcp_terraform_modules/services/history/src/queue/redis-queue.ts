import { hostname } from 'node:os';
import type { RedisClientType } from 'redis';
import { blockingRedis, redis } from '../redis.ts';
import { errorMessage } from '../core/errors.ts';
import { parseResult, storeResult } from './store-result.ts';
import type { PriceRequest, Queue } from './types.ts';

// Streams carrying the conversation with the fetcher: requests one way, results the other.
const STREAM_REQUESTS = 'price:requests';
const STREAM_RESULTS = 'price:results';
const GROUP = 'history';
const MAX_STREAM_LEN = 1000;
// The container hostname: one consumer name per history instance.
const CONSUMER = hostname();
// Unacked results older than this are taken over and retried.
const RECLAIM_IDLE_MS = 30_000;
const BLOCK_MS = 5000;
// One quote request per pair in flight at a time.
const DEDUP_TTL_S = 30;

/** BACKEND=redis: Redis Streams with a consumer group; ack after the write, XAUTOCLAIM for retries. */
export const redisQueue: Queue = {
  async requestPrice(request: PriceRequest): Promise<string | null> {
    const client = await redis();
    if (!request.days) {
      const acquired = await client.set(`pending:${request.coin}:${request.vs}`, '1', { NX: true, EX: DEDUP_TTL_S });
      if (acquired === null) return null;
    }
    return client.xAdd(
      STREAM_REQUESTS,
      '*',
      { payload: JSON.stringify(request) },
      { TRIM: { strategy: 'MAXLEN', strategyModifier: '~', threshold: MAX_STREAM_LEN } },
    );
  },

  async startConsumer(): Promise<void> {
    await ensureGroup();
    const reader = await blockingRedis();
    console.log(`[history] consuming ${STREAM_RESULTS} as ${CONSUMER}`);
    void loop(reader);
  },
};

/** Creates the consumer group, tolerating the one that already exists. */
async function ensureGroup(): Promise<void> {
  try {
    await (await redis()).xGroupCreate(STREAM_RESULTS, GROUP, '0', { MKSTREAM: true });
  } catch (err) {
    if (!errorMessage(err).includes('BUSYGROUP')) throw err;
  }
}

async function loop(reader: RedisClientType): Promise<void> {
  for (;;) {
    try {
      await readOnce(reader);
    } catch (err) {
      const message = errorMessage(err);
      console.error(`[history] consumer read failed: ${message}`);
      // Losing Redis data (no AOF, a new volume) takes the group with it.
      if (message.includes('NOGROUP')) await ensureGroup().catch(() => undefined);
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
  }
}

async function readOnce(reader: RedisClientType): Promise<void> {
  // '>' returns only new messages; a result whose write failed would stay pending forever.
  const claimed = await reader.xAutoClaim(STREAM_RESULTS, GROUP, CONSUMER, RECLAIM_IDLE_MS, '0', { COUNT: 10 });
  for (const message of claimed.messages) {
    if (message) await handle(reader, message.id, message.message.payload);
  }

  const response = await reader.xReadGroup(
    GROUP, CONSUMER, [{ key: STREAM_RESULTS, id: '>' }], { COUNT: 10, BLOCK: BLOCK_MS },
  );
  for (const stream of response ?? []) {
    for (const message of stream.messages) {
      await handle(reader, message.id, message.message.payload);
    }
  }
}

async function handle(reader: RedisClientType, id: string, raw: string | undefined): Promise<void> {
  let payload;
  try {
    payload = parseResult(JSON.parse(raw ?? ''));
  } catch {
    payload = null;
  }
  if (!payload) {
    // Malformed: acknowledge it, retrying cannot help.
    console.error(`[history] bad result ${id}, dropped`);
    await reader.xAck(STREAM_RESULTS, GROUP, id);
    return;
  }

  try {
    await storeResult(payload);
  } catch (err) {
    // No ack: the message is reclaimed after RECLAIM_IDLE_MS; the rest of the batch goes on.
    console.error(`[history] result ${id} failed: ${errorMessage(err)}`);
    return;
  }
  await reader.xAck(STREAM_RESULTS, GROUP, id);
}
