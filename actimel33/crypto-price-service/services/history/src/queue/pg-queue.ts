import pg from 'pg';
import { config } from '../config.ts';
import { query } from '../db/pool.ts';
import { errorMessage } from '../core/errors.ts';
import { storeResult } from './store-result.ts';
import type { PriceRequest, Queue, ResultPayload } from './types.ts';

const TOPIC_REQUESTS = 'price:requests';
const TOPIC_RESULTS = 'price:results';
// A taken message is invisible for this long; without an ack it is retried.
const LEASE_S = 30;
const BATCH = 10;
// Fallback for a missed notification.
const POLL_MS = 5000;

/** Postgres-backed queue: queue_messages table, SKIP LOCKED + lease, LISTEN/NOTIFY to wake up. */
export const pgQueue: Queue = {
  async requestPrice(request: PriceRequest): Promise<string | null> {
    // A duplicate pending quote hits uq_queue_pending_quote and inserts nothing.
    const { rows } = await query<{ id: string }>(
      `INSERT INTO queue_messages (topic, payload) VALUES ($1, $2)
       ON CONFLICT DO NOTHING RETURNING id`,
      [TOPIC_REQUESTS, JSON.stringify(request)],
    );
    return rows[0]?.id ?? null;
  },

  async startConsumer(): Promise<void> {
    console.log(`[history] consuming ${TOPIC_RESULTS} from postgres`);
    const wake = new Wakeup();
    void listen(TOPIC_RESULTS, wake);
    void loop(wake);
  },
};

async function loop(wake: Wakeup): Promise<void> {
  for (;;) {
    try {
      const taken = await take(TOPIC_RESULTS);
      for (const message of taken) await handle(message);
      if (taken.length === BATCH) continue; // more may be waiting
    } catch (err) {
      console.error(`[history] queue read failed: ${errorMessage(err)}`);
    }
    await wake.wait(POLL_MS);
  }
}

/** Leases up to BATCH ready messages; other consumers skip the locked rows. */
async function take(topic: string): Promise<{ id: string; payload: ResultPayload }[]> {
  const { rows } = await query<{ id: string; payload: ResultPayload }>(
    `UPDATE queue_messages
        SET available_at = now() + make_interval(secs => $2), attempts = attempts + 1
      WHERE id IN (SELECT id FROM queue_messages
                    WHERE topic = $1 AND available_at <= now()
                    ORDER BY id LIMIT $3
                    FOR UPDATE SKIP LOCKED)
      RETURNING id, payload`,
    [topic, LEASE_S, BATCH],
  );
  return rows.sort((a, b) => Number(a.id) - Number(b.id));
}

async function handle(message: { id: string; payload: ResultPayload }): Promise<void> {
  try {
    await storeResult(message.payload);
  } catch (err) {
    // No ack: the lease expires and the message is retried.
    console.error(`[history] result ${message.id} failed: ${errorMessage(err)}`);
    return;
  }
  await query('DELETE FROM queue_messages WHERE id = $1', [message.id]);
}

/** Keeps a dedicated connection on LISTEN; reconnects after a drop. */
async function listen(topic: string, wake: Wakeup): Promise<void> {
  for (;;) {
    const client = new pg.Client({ connectionString: config.databaseUrl });
    // Handlers first: an 'error' event without a listener would crash the process.
    const closed = new Promise<void>((resolve) => {
      client.on('error', (err: Error) => {
        console.error(`[history] listen connection lost: ${err.message}`);
        resolve();
      });
      client.on('end', () => resolve());
    });
    client.on('notification', () => wake.fire());
    try {
      await client.connect();
      await client.query(`LISTEN "${topic}"`);
      await closed;
    } catch (err) {
      console.error(`[history] listen failed: ${errorMessage(err)}`);
    }
    await client.end().catch(() => undefined);
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
}

/** A sleep that a notification can cut short. */
class Wakeup {
  private resolve: (() => void) | null = null;
  private pending = false;

  fire(): void {
    if (this.resolve) {
      this.resolve();
      this.resolve = null;
    } else {
      this.pending = true; // arrived while busy: skip the next wait
    }
  }

  wait(ms: number): Promise<void> {
    if (this.pending) {
      this.pending = false;
      return Promise.resolve();
    }
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.resolve = null;
        resolve();
      }, ms);
      this.resolve = () => {
        clearTimeout(timer);
        resolve();
      };
    });
  }
}
