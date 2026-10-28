import { query } from '../db/pool.ts';
import { errorMessage } from '../core/errors.ts';
import { parseResult, storeResult } from './store-result.ts';
import type { PriceRequest, Queue } from './types.ts';

// pgmq queues, created by 003_pgmq.sql.
const QUEUE_REQUESTS = 'price_requests';
const QUEUE_RESULTS = 'price_results';
// A read message is invisible for this long; without a delete it comes back.
const LEASE_S = 30;
const BATCH = 10;
// read_with_poll waits this long on the server when the queue is empty.
const POLL_S = 5;

const UNIQUE_VIOLATION = '23505';

/** BACKEND=postgres: the pgmq extension, send / read_with_poll / delete. */
export const pgQueue: Queue = {
  async requestPrice(request: PriceRequest): Promise<string | null> {
    try {
      const { rows } = await query<{ id: string }>(
        'SELECT pgmq.send($1, $2::jsonb) AS id',
        [QUEUE_REQUESTS, JSON.stringify(request)],
      );
      return rows[0]?.id ?? null;
    } catch (err) {
      // uq_pending_quote: the same quote request is already waiting.
      if ((err as { code?: string }).code === UNIQUE_VIOLATION) return null;
      throw err;
    }
  },

  async startConsumer(): Promise<void> {
    console.log(`[history] consuming ${QUEUE_RESULTS} from pgmq`);
    void loop();
  },
};

async function loop(): Promise<void> {
  for (;;) {
    try {
      const { rows } = await query<{ msg_id: string; message: unknown }>(
        'SELECT msg_id, message FROM pgmq.read_with_poll($1, $2, $3, $4)',
        [QUEUE_RESULTS, LEASE_S, BATCH, POLL_S],
      );
      for (const row of rows) await handle(row.msg_id, row.message);
    } catch (err) {
      console.error(`[history] queue read failed: ${errorMessage(err)}`);
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
  }
}

async function handle(id: string, message: unknown): Promise<void> {
  const payload = parseResult(message);
  if (!payload) {
    // Malformed: drop it, retrying cannot help.
    console.error(`[history] bad result ${id}, dropped`);
    await query('SELECT pgmq.delete($1, $2::bigint)', [QUEUE_RESULTS, id]);
    return;
  }
  try {
    await storeResult(payload);
  } catch (err) {
    // No delete: the lease expires and the result is retried.
    console.error(`[history] result ${id} failed: ${errorMessage(err)}`);
    return;
  }
  await query('SELECT pgmq.delete($1, $2::bigint)', [QUEUE_RESULTS, id]);
}
