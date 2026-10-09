import { query } from './pool.ts';
import type { Origin, PricePoint, StoredPoint } from '../core/types.ts';

type Row = {
  coin: string;
  vs_currency: string;
  price: string;
  observed_at: Date;
  origin: Origin;
};

// pg returns NUMERIC as a string — convert it to a number in one place.
const toStored = (row: Row): StoredPoint => ({
  coin: row.coin,
  vs: row.vs_currency,
  price: Number(row.price),
  observedAt: row.observed_at,
  origin: row.origin,
});

/** Writes a batch of points in one statement. Duplicates on (coin, vs, observed_at) are skipped silently. */
export async function insertMany(
  coin: string,
  vs: string,
  points: PricePoint[],
  origin: Origin,
): Promise<number> {
  if (points.length === 0) return 0;

  const values: unknown[] = [];
  const tuples = points.map((point, index) => {
    const base = index * 5;
    values.push(coin, vs, point.price, point.observedAt, origin);
    return `($${base + 1}, $${base + 2}, $${base + 3}, $${base + 4}, $${base + 5})`;
  });

  const result = await query(
    `INSERT INTO price_points (coin, vs_currency, price, observed_at, source)
     VALUES ${tuples.join(', ')}
     ON CONFLICT (coin, vs_currency, observed_at) DO NOTHING`,
    values,
  );
  return result.rowCount ?? 0;
}

export async function latest(coin: string, vs: string): Promise<StoredPoint | null> {
  const { rows } = await query<Row>(
    `SELECT coin, vs_currency, price, observed_at, source AS origin
       FROM price_points
      WHERE coin = $1 AND vs_currency = $2
      ORDER BY observed_at DESC
      LIMIT 1`,
    [coin, vs],
  );
  return rows.length > 0 ? toStored(rows[0]!) : null;
}

export async function range(
  coin: string,
  vs: string,
  from: Date,
  to: Date,
  limit: number,
): Promise<PricePoint[]> {
  const { rows } = await query<Row>(
    `SELECT coin, vs_currency, price, observed_at, source AS origin
       FROM price_points
      WHERE coin = $1 AND vs_currency = $2
        AND observed_at >= $3 AND observed_at <= $4
      ORDER BY observed_at ASC
      LIMIT $5`,
    [coin, vs, from, to, limit],
  );
  return rows.map(toStored).map(({ price, observedAt }) => ({ price, observedAt }));
}

export async function countFor(coin: string, vs: string): Promise<number> {
  const { rows } = await query<{ total: string }>(
    'SELECT count(*) AS total FROM price_points WHERE coin = $1 AND vs_currency = $2',
    [coin, vs],
  );
  return Number(rows[0]?.total ?? 0);
}
