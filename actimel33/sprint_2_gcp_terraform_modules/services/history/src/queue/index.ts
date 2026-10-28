import { config } from '../config.ts';
import { pgQueue } from './pg-queue.ts';
import { redisQueue } from './redis-queue.ts';

/** Chosen once at startup by BACKEND. */
export const queue = config.backend === 'postgres' ? pgQueue : redisQueue;
