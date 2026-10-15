/**
 * pgmq (PostgreSQL message queue) client of the History service: the same request/reply as over RabbitMQ.
 * A request is the unchanged JSON message in REQUEST_QUEUE; what AMQP keeps in message properties
 * (correlationId, replyTo, expiration) goes into the pgmq headers. The Fetcher sends its reply to
 * REPLY_QUEUE with the same correlationId in the headers; one connection long-polls that queue.
 */
import { randomUUID } from 'node:crypto';
import pg from 'pg';
import config from '../config.js';
import { MAX_RECONNECT_DELAY_MS, PendingRequests, parseReply } from './pending.js';

export const REQUEST_QUEUE = 'weather_fetch_requests';
export const REPLY_QUEUE = 'weather_fetch_replies';
// read_with_poll: hide read replies for 30 s, take up to 50, wait up to 5 s and check every 250 ms
const POLL_ARGS = [30, 50, 5, 250];

const pending = new PendingRequests();
let pool = null;
let polling = false; // true while the reply queue is being read
let reconnectDelay = 1000;

export const isReady = () => polling;

/** Creates the extension and both queues if missing (idempotent, like assertQueue). */
async function declareQueues(client) {
  await client.query('CREATE EXTENSION IF NOT EXISTS pgmq');
  for (const queue of [REQUEST_QUEUE, REPLY_QUEUE]) {
    await client.query('SELECT pgmq.create($1)', [queue]);
  }
}

async function readReplies(client) {
  for (;;) {
    const { rows } = await client.query(
      'SELECT msg_id, message, headers FROM pgmq.read_with_poll($1, $2, $3, $4, $5)',
      [REPLY_QUEUE, ...POLL_ARGS],
    );
    for (const row of rows) {
      const id = row.headers?.correlationId;
      if (!pending.settle(id, parseReply(row.message))) {
        console.warn(`pgmq: dropping a reply nobody waits for (correlationId ${id})`);
      }
    }
    if (rows.length > 0) {
      await client.query('SELECT pgmq.delete($1, $2::bigint[])', [REPLY_QUEUE, rows.map((row) => row.msg_id)]);
    }
  }
}

async function run() {
  let client;
  try {
    client = await pool.connect();
    // An error between queries would otherwise crash the process; the next query fails and we reconnect
    client.on('error', () => {});
    await declareQueues(client);
    polling = true;
    reconnectDelay = 1000;
    console.log('pgmq connected');
    await readReplies(client);
  } catch (err) {
    polling = false;
    client?.release(err); // a broken connection is dropped, not returned to the pool
    console.error(`pgmq: ${err.message}. Retrying in ${reconnectDelay / 1000}s`);
    setTimeout(run, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY_MS);
  }
}

/** Connects in the background and keeps reconnecting; fetch requests fail fast meanwhile. */
export function connectBroker() {
  // One connection reads replies, the others send requests
  pool = new pg.Pool({ connectionString: config.databaseUrl, max: 3 });
  // Without an 'error' listener a broken idle connection would crash the process
  pool.on('error', (err) => console.error('pgmq:', err.message));
  run();
}

/**
 * Sends `message` to the Fetcher and resolves with its reply ({ ok, data } or { ok: false, error, kind }).
 * pgmq has no per-message TTL: the Fetcher drops a request whose expiresAt has passed.
 */
export function request(message, timeoutMs) {
  if (!polling) return Promise.reject(new Error('message broker is not connected'));
  const correlationId = randomUUID();
  const headers = { correlationId, replyTo: REPLY_QUEUE, expiresAt: new Date(Date.now() + timeoutMs).toISOString() };
  // Registered before sending: the reply can be read on the other connection before the send returns
  const reply = pending.add(correlationId, timeoutMs);
  pool
    .query('SELECT pgmq.send($1, $2::jsonb, $3::jsonb)', [REQUEST_QUEUE, JSON.stringify(message), JSON.stringify(headers)])
    .catch((err) => pending.fail(correlationId, err));
  return reply;
}
