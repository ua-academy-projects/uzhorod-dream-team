import { hostname } from 'node:os';
import { GROUP_HISTORY, STREAM_RESULTS, ensureGroup, redis } from './client.ts';
import { storeResult } from './store-result.ts';
import { errorMessage } from '../core/errors.ts';
import type { ResultPayload } from './types.ts';

// Unique per instance, so several history services can share the group.
const CONSUMER = hostname();
// Unacked results older than this are taken over and retried.
const RECLAIM_IDLE_MS = 30_000;
const BLOCK_MS = 5000;

/**
 * Consumes results the fetcher published and stores them. A message is
 * acknowledged only after a successful write, so a crash mid-way leaves it
 * for the next read instead of losing the data.
 */
export async function startConsumer(): Promise<void> {
  await ensureGroup(STREAM_RESULTS, GROUP_HISTORY);
  console.log(`[history] consuming ${STREAM_RESULTS} as ${CONSUMER}`);
  void loop();
}

async function loop(): Promise<void> {
  for (;;) {
    try {
      await readOnce();
    } catch (err) {
      const message = errorMessage(err);
      // Redis keeps no data on disk here, so a restart wipes the stream and the
      // group with it. Recreate them instead of looping on the error forever.
      if (message.includes('NOGROUP')) {
        console.log('[history] consumer group vanished, recreating');
        await ensureGroup(STREAM_RESULTS, GROUP_HISTORY);
        continue;
      }
      console.error(`[history] consumer read failed: ${message}`);
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
  }
}

async function readOnce(): Promise<void> {
  const connection = await redis();

  // '>' returns only new messages; a result whose write failed would stay pending forever.
  const claimed = await connection.xAutoClaim(
    STREAM_RESULTS, GROUP_HISTORY, CONSUMER, RECLAIM_IDLE_MS, '0', { COUNT: 10 },
  );
  for (const message of claimed.messages) {
    if (message) await handle(message.id, message.message.payload);
  }

  const response = await connection.xReadGroup(
    GROUP_HISTORY,
    CONSUMER,
    [{ key: STREAM_RESULTS, id: '>' }],
    { COUNT: 10, BLOCK: BLOCK_MS },
  );
  if (!response) return;

  for (const stream of response) {
    for (const message of stream.messages) {
      await handle(message.id, message.message.payload);
    }
  }
}

async function handle(id: string, raw: string | undefined): Promise<void> {
  const connection = await redis();

  let payload: ResultPayload;
  try {
    payload = JSON.parse(raw ?? '') as ResultPayload;
  } catch {
    // Unparseable message: acknowledge it, retrying cannot help.
    console.error(`[history] bad result ${id}, dropped`);
    await connection.xAck(STREAM_RESULTS, GROUP_HISTORY, id);
    return;
  }

  await storeResult(payload);
  await connection.xAck(STREAM_RESULTS, GROUP_HISTORY, id);
}
