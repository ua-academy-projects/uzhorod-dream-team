import { Router } from 'express';
import type { Request, Response } from 'express';
import { config } from '../../config.ts';
import { isDbAlive } from '../../db/pool.ts';

export const healthRoutes = Router();

healthRoutes.get('/health', async (_req: Request, res: Response) => {
  const alive = await isDbAlive();
  res
    .status(alive ? 200 : 503)
    .json({ status: alive ? 'ok' : 'degraded', db: alive ? 'ok' : 'down', backend: config.backend });
});
