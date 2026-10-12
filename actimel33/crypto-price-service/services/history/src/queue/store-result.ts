import * as repo from '../db/price-repo.ts';
import type { PricePoint } from '../core/types.ts';
import type { ResultPayload } from './types.ts';

/** Writes a fetched result to the database. Shared by both queue drivers. */
export async function storeResult(payload: ResultPayload): Promise<void> {
  const points: PricePoint[] = payload.points
    .map((p) => ({ price: p.price, observedAt: new Date(p.observedAt) }))
    .filter((p) => Number.isFinite(p.price) && !Number.isNaN(p.observedAt.getTime()));

  const inserted = await repo.insertMany(payload.coin, payload.vs, points, payload.origin);
  console.log(`[history] stored ${inserted}/${points.length} ${payload.coin}/${payload.vs} (${payload.origin})`);
}
