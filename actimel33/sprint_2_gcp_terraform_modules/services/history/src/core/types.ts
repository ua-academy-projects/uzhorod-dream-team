/** How a point got into the database (price_points.source). */
export const ORIGINS = ['bootstrap', 'timer', 'on_demand'] as const;
export type Origin = (typeof ORIGINS)[number];

export type PricePoint = {
  price: number;
  observedAt: Date;
};

/** The response to a current price request: always from the database. */
export type LatestResult = PricePoint & {
  coin: string;
  vs: string;
  stale: boolean;
  staleReason?: string;
};
