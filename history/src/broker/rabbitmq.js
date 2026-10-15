/**
 * RabbitMQ client of the History service: request/reply with the Fetcher over two queues.
 * A request goes to REQUEST_QUEUE with replyTo=REPLY_QUEUE and a fresh correlationId; the Fetcher
 * publishes its reply to REPLY_QUEUE with the same correlationId, which settles the waiting promise.
 * (One shared reply queue is enough for a single History instance.)
 */
import { randomUUID } from 'node:crypto';
import amqp from 'amqplib';
import config from '../config.js';
import { MAX_RECONNECT_DELAY_MS, PendingRequests, parseReply } from './pending.js';

export const REQUEST_QUEUE = 'weather.fetch.requests';
export const REPLY_QUEUE = 'weather.fetch.replies';

const pending = new PendingRequests();
let channel = null; // set only while connected and consuming replies
let reconnectDelay = 1000;

export const isReady = () => channel !== null;

async function connect() {
  const conn = await amqp.connect(config.amqpUrl);
  // Without an 'error' listener a broken connection would crash the process
  conn.on('error', (err) => console.error('RabbitMQ:', err.message));
  try {
    const ch = await conn.createChannel();
    // Same declarations as the Fetcher, so start-up order does not matter
    await ch.assertQueue(REQUEST_QUEUE, { durable: true });
    await ch.assertQueue(REPLY_QUEUE, { durable: true });
    await ch.consume(REPLY_QUEUE, (msg) => {
      if (!msg) return; // consumer cancelled by the broker; the connection 'close' handler reconnects
      const id = msg.properties.correlationId;
      if (!pending.settle(id, parseReply(msg.content.toString()))) {
        console.warn(`RabbitMQ: dropping a reply nobody waits for (correlationId ${id})`);
      }
      ch.ack(msg);
    });
    // A channel-level error closes only the channel: close the connection too, so we reconnect
    ch.on('close', () => conn.close().catch(() => {}));
    conn.on('close', () => {
      channel = null;
      console.error('RabbitMQ: connection closed, reconnecting');
      setTimeout(connectBroker, 1000);
    });
    channel = ch;
  } catch (err) {
    await conn.close().catch(() => {});
    throw err;
  }
}

/** Connects in the background and keeps reconnecting; fetch requests fail fast meanwhile. */
export function connectBroker() {
  connect()
    .then(() => {
      reconnectDelay = 1000;
      console.log('RabbitMQ connected');
    })
    .catch((err) => {
      console.error(`RabbitMQ: cannot connect: ${err.message}. Retrying in ${reconnectDelay / 1000}s`);
      setTimeout(connectBroker, reconnectDelay);
      reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY_MS);
    });
}

/**
 * Sends `message` to the Fetcher and resolves with its reply ({ ok, data } or { ok: false, error, kind }).
 * The request expires in the queue together with our timeout, so the Fetcher never works for nobody.
 */
export function request(message, timeoutMs) {
  if (!channel) return Promise.reject(new Error('message broker is not connected'));
  const correlationId = randomUUID();
  channel.sendToQueue(REQUEST_QUEUE, Buffer.from(JSON.stringify(message)), {
    correlationId,
    replyTo: REPLY_QUEUE,
    expiration: String(timeoutMs),
    persistent: true,
    contentType: 'application/json',
  });
  // Registered after sending is fine: the reply is handled in a later event-loop turn
  return pending.add(correlationId, timeoutMs);
}
