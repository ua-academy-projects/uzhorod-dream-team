/**
 * HTTP layer of the History service: parses/validates input and delegates to history.service.
 */
import { Router } from 'express';
import config from './config.js';
import { MAX_HISTORY_DAYS } from './fetcherClient.js';
import * as history from './service.js';

export class BadRequestError extends Error {
  status = 400;
}

// Express 4 does not forward rejected promises to the error handler by itself
export const asyncHandler = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

function requireTriggerToken(req, res, next) {
  if (config.triggerToken && req.get('X-Trigger-Token') !== config.triggerToken) {
    return res.status(401).json({ error: 'Invalid or missing X-Trigger-Token' });
  }
  next();
}

function parseDate(value, name) {
  if (value === undefined || value === '') return undefined;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) throw new BadRequestError(`"${name}" must be an ISO date`);
  return date;
}

function parsePositiveInt(value, name) {
  if (value === undefined || value === '') return undefined;
  const n = Number(value);
  if (!Number.isInteger(n) || n < 1) throw new BadRequestError(`"${name}" must be a positive integer`);
  return n;
}

const router = Router();

router.post(
  '/fetch',
  requireTriggerToken,
  asyncHandler(async (req, res) => {
    const observation = await history.triggerFetch();
    console.log(`Fetched current weather for ${observation.locationName} @ ${observation.observedAt.toISOString()}`);
    res.status(201).json(observation);
  }),
);

router.post(
  '/backfill',
  requireTriggerToken,
  asyncHandler(async (req, res) => {
    const days = parsePositiveInt(req.body?.days, 'days') ?? 7;
    if (days > MAX_HISTORY_DAYS) throw new BadRequestError(`"days" must be at most ${MAX_HISTORY_DAYS}`);
    res.status(201).json(await history.backfill(days));
  }),
);

router.get(
  '/latest',
  asyncHandler(async (req, res) => {
    const observation = await history.getLatest();
    if (!observation) return res.status(404).json({ error: 'No observations stored yet' });
    res.json(observation);
  }),
);

router.get(
  '/history',
  asyncHandler(async (req, res) => {
    const from = parseDate(req.query.from, 'from');
    const to = parseDate(req.query.to, 'to');
    if (from && to && from > to) throw new BadRequestError('"from" must be before "to"');
    const limit = parsePositiveInt(req.query.limit, 'limit');
    res.json(await history.getHistory({ from, to, limit }));
  }),
);

export default router;
