import * as repo from '../db/price-repo.ts';
import { ORIGINS } from '../core/types.ts';
import type { PricePoint } from '../core/types.ts';
import type { ResultPayload } from './types.ts';

/** A message from the queue, checked: null means malformed, and a retry cannot fix it. */
export function parseResult(value: unknown): ResultPayload | null {
  const v = value as Partial<ResultPayload> | null;
  const valid = typeof v?.coin === 'string'
    && typeof v.vs === 'string'
    && (ORIGINS as readonly unknown[]).includes(v.origin)
    && Array.isArray(v.points);
  return valid ? (v as ResultPayload) : null;
}

/** Writes a fetched result to the database. Shared by both queue drivers. */
export async function storeResult(payload: ResultPayload): Promise<void> {
  const points: PricePoint[] = payload.points
    .map((p) => ({ price: Number(p?.price), observedAt: new Date(p?.observedAt) }))
    .filter((p) => Number.isFinite(p.price) && !Number.isNaN(p.observedAt.getTime()));

  const inserted = await repo.insertMany(payload.coin, payload.vs, points, payload.origin);
  console.log(`[history] stored ${inserted}/${points.length} ${payload.coin}/${payload.vs} (${payload.origin})`);
}
