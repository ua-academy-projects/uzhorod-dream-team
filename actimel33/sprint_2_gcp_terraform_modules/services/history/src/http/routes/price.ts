import { Router } from 'express';
import type { Request, Response } from 'express';
import { config } from '../../config.ts';
import { BadRequestError } from '../../core/errors.ts';
import * as service from '../../core/price-service.ts';
import type { LatestResult } from '../../core/types.ts';
import { asset, boundedInt, isoDate } from '../validate.ts';

const DAY_MS = 86_400_000;
const DEFAULT_SPAN_DAYS = 7;
const MAX_LIMIT = 5000;

const present = (result: LatestResult) => ({
  ...result,
  observedAt: result.observedAt.toISOString(),
});

export const priceRoutes = Router();

priceRoutes.get('/price/latest', async (req: Request, res: Response) => {
  const coin = asset(req.query.coin, config.defaultCoin, 'coin');
  const vs = asset(req.query.vs, config.defaultVs, 'vs');
  res.json(present(await service.getLatest(coin, vs)));
});

priceRoutes.post('/refresh', async (req: Request, res: Response) => {
  const coin = asset(req.query.coin, config.defaultCoin, 'coin');
  const vs = asset(req.query.vs, config.defaultVs, 'vs');
  // Accepted, not done: the fetcher answers through the results stream, and
  // the next read of /price/latest will see the new point.
  const id = await service.refresh(coin, vs);
  res.status(202).json({ queued: id !== null, id, coin, vs });
});

priceRoutes.get('/price/history', async (req: Request, res: Response) => {
  const coin = asset(req.query.coin, config.defaultCoin, 'coin');
  const vs = asset(req.query.vs, config.defaultVs, 'vs');
  const to = isoDate(req.query.to, new Date(), 'to');
  const from = isoDate(req.query.from, new Date(to.getTime() - DEFAULT_SPAN_DAYS * DAY_MS), 'from');
  const limit = boundedInt(req.query.limit, 1000, MAX_LIMIT, 'limit');

  if (from.getTime() > to.getTime()) {
    throw new BadRequestError("invalid range: 'from' is later than 'to'");
  }

  const points = await service.getHistory(coin, vs, from, to, limit);
  res.json({
    coin, vs,
    from: from.toISOString(),
    to: to.toISOString(),
    points: points.map((p) => ({ price: p.price, observedAt: p.observedAt.toISOString() })),
  });
});
