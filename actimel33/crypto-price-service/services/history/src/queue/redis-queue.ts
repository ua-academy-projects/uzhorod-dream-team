import { startConsumer } from './consumer.ts';
import { requestPrice } from './publisher.ts';
import type { Queue } from './types.ts';

/** Redis Streams driver: price:requests / price:results with consumer groups. */
export const redisQueue: Queue = { requestPrice, startConsumer };
