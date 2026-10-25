import type { Origin } from '../core/types.ts';

export type PriceRequest = {
  coin: string;
  vs: string;
  /** Days of history instead of a single quote. */
  days?: number;
};

export type ResultPayload = {
  coin: string;
  vs: string;
  origin: Origin;
  points: { price: number; observedAt: string }[];
};

/** Both drivers expose the same two operations; the rest of history does not know which one runs. */
export type Queue = {
  /** Queues a request; null when an identical quote request is already in flight. */
  requestPrice(request: PriceRequest): Promise<string | null>;
  /** Starts consuming results in the background. */
  startConsumer(): Promise<void>;
};
