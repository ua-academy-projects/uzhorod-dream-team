import { MAX_STREAM_LEN, STREAM_REQUESTS, redis } from './client.ts';

export type PriceRequest = {
  coin: string;
  vs: string;
  /** Days of history instead of a single quote. */
  days?: number;
};

/** One quote request per pair in flight at a time. */
const DEDUP_TTL_S = 30;

/**
 * Queues a request; the answer arrives later through the results stream.
 * Returns null when an identical quote request is already in flight.
 */
export async function requestPrice(request: PriceRequest): Promise<string | null> {
  const connection = await redis();

  if (!request.days) {
    const key = `pending:${request.coin}:${request.vs}`;
    const acquired = await connection.set(key, '1', { NX: true, EX: DEDUP_TTL_S });
    if (acquired === null) return null;
  }

  return connection.xAdd(
    STREAM_REQUESTS,
    '*',
    { payload: JSON.stringify(request) },
    { TRIM: { strategy: 'MAXLEN', strategyModifier: '~', threshold: MAX_STREAM_LEN } },
  );
}
