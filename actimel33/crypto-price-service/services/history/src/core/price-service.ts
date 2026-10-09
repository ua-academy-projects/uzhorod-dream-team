import { config } from '../config.ts';
import * as repo from '../db/price-repo.ts';
import { requestPrice } from '../queue/publisher.ts';
import { NoDataError, errorMessage } from './errors.ts';
import type { LatestResult, PricePoint } from './types.ts';

const isFresh = (observedAt: Date): boolean =>
  Date.now() - observedAt.getTime() < config.cacheTtlMs;

/**
 * Answers from the database, always. When the stored point is stale it also
 * queues a request, so the next call will find fresher data — the fetcher
 * answers through the results stream, not through this call.
 */
export async function getLatest(coin: string, vs: string): Promise<LatestResult> {
  const stored = await repo.latest(coin, vs);

  if (stored === null) {
    await queueQuietly({ coin, vs });
    throw new NoDataError(`no stored data for ${coin}/${vs} yet, a request has been queued`);
  }

  const fresh = isFresh(stored.observedAt);
  if (!fresh) await queueQuietly({ coin, vs });

  return {
    coin,
    vs,
    price: stored.price,
    observedAt: stored.observedAt,
    source: 'cache',
    stale: !fresh,
    ...(fresh ? {} : { staleReason: 'an update is on its way' }),
  };
}

/** Queues a refresh regardless of the TTL. Returns once the request is queued. */
export async function refresh(coin: string, vs: string): Promise<string | null> {
  return requestPrice({ coin, vs });
}

export const getHistory = (
  coin: string, vs: string, from: Date, to: Date, limit: number,
): Promise<PricePoint[]> => repo.range(coin, vs, from, to, limit);

/** Asks for a week of history once, when the database is still empty. */
export async function bootstrap(): Promise<void> {
  const { defaultCoin: coin, defaultVs: vs, bootstrapDays: days } = config;
  try {
    const existing = await repo.countFor(coin, vs);
    if (existing > 0) {
      console.log(`[history] bootstrap skipped: ${existing} points already stored`);
      return;
    }
    await requestPrice({ coin, vs, days });
    console.log(`[history] bootstrap: requested ${days}d of history`);
  } catch (err) {
    console.error(`[history] bootstrap failed (starting anyway): ${errorMessage(err)}`);
  }
}

/** A queue failure must not break a read that the database can already answer. */
async function queueQuietly(request: { coin: string; vs: string }): Promise<void> {
  try {
    await requestPrice(request);
  } catch (err) {
    console.error(`[history] could not queue a request: ${errorMessage(err)}`);
  }
}
