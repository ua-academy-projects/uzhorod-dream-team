import { config } from '../config.ts';
import { pgQueue } from './pg-queue.ts';
import { redisQueue } from './redis-queue.ts';

/** Chosen once at startup by QUEUE_DRIVER. */
export const queue = config.queueDriver === 'postgres' ? pgQueue : redisQueue;
