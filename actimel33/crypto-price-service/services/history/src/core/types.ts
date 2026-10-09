/** How the point got into the database. This is NOT the same as `source` in the API response. */
export type Origin = 'bootstrap' | 'timer' | 'on_demand';

export type PricePoint = {
  price: number;
  observedAt: Date;
};

export type StoredPoint = PricePoint & {
  coin: string;
  vs: string;
  origin: Origin;
};

/**
 * The response to a current price request.
 * Here `source` answers a different question than `origin`: served from the database or fetched live.
 */
export type LatestResult = {
  coin: string;
  vs: string;
  price: number;
  observedAt: Date;
  source: 'cache' | 'live';
  stale: boolean;
  staleReason?: string;
};
