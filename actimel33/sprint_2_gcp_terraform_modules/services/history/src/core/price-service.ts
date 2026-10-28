import { config } from '../config.ts';
import * as repo from '../db/price-repo.ts';
import { queue } from '../queue/index.ts';
import { NoDataError, NotFoundError, errorMessage } from './errors.ts';
import type { LatestResult, PricePoint } from './types.ts';

const isFresh = (observedAt: Date): boolean =>
  Date.now() - observedAt.getTime() < config.cacheTtlMs;

const isDefaultPair = (coin: string, vs: string): boolean =>
  coin === config.defaultCoin && vs === config.defaultVs;

/**
 * Only the default pair or one already stored may reach the fetcher: any other
 * name would cost a CoinGecko call per request.
 */
async function assertTracked(coin: string, vs: string): Promise<void> {
  if (isDefaultPair(coin, vs) || (await repo.countFor(coin, vs)) > 0) return;
  throw new NotFoundError(`${coin}/${vs} is not tracked`);
}

/**
 * Answers from the database, always. When the stored point is stale it also
 * queues a request, so the next call will find fresher data — the fetcher
 * answers through the results stream, not through this call.
 */
export async function getLatest(coin: string, vs: string): Promise<LatestResult> {
  const stored = await repo.latest(coin, vs);

  if (stored === null) {
    await assertTracked(coin, vs);
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
    stale: !fresh,
    ...(fresh ? {} : { staleReason: 'an update is on its way' }),
  };
}

/** Queues a refresh regardless of the TTL. Returns once the request is queued. */
export async function refresh(coin: string, vs: string): Promise<string | null> {
  await assertTracked(coin, vs);
  return queue.requestPrice({ coin, vs });
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
    await queue.requestPrice({ coin, vs, days });
    console.log(`[history] bootstrap: requested ${days}d of history`);
  } catch (err) {
    console.error(`[history] bootstrap failed (starting anyway): ${errorMessage(err)}`);
  }
}

/** A queue failure must not break a read that the database can already answer. */
async function queueQuietly(request: { coin: string; vs: string }): Promise<void> {
  try {
    await queue.requestPrice(request);
  } catch (err) {
    console.error(`[history] could not queue a request: ${errorMessage(err)}`);
  }
}
