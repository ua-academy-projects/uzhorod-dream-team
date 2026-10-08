/**
 * Client for the Fetcher service over RabbitMQ (no direct HTTP between the services).
 * Same interface as the Fetcher core (fetchCurrent / fetchRecentHistory), so the History service
 * doesn't care how the Fetcher is reached.
 */
import config from './config.js';
import * as broker from './broker.js';

export const MAX_HISTORY_DAYS = 92; // must match the Fetcher service limit

export class FetcherError extends Error {
  constructor(message, { kind, cause } = {}) {
    super(message, { cause });
    this.name = 'FetcherError';
    this.kind = kind;
  }
}

async function call(message) {
  let reply;
  try {
    reply = await broker.request(message);
  } catch (err) {
    throw new FetcherError(`Fetcher request failed: ${err.message}`, { cause: err });
  }
  if (!reply.ok) {
    throw new FetcherError(`Fetcher replied with an error (${reply.kind}): ${reply.error ?? ''}`, { kind: reply.kind });
  }
  return reply.data;
}

const locationParams = (location) => ({
  name: location.name,
  latitude: location.latitude,
  longitude: location.longitude,
});

// JSON has no Date type: observedAt arrives as an ISO string
const revive = (observation) => ({ ...observation, observedAt: new Date(observation.observedAt) });

export async function fetchCurrent(location = config.location) {
  return revive(await call({ type: 'current', location: locationParams(location) }));
}

export async function fetchRecentHistory(location = config.location, days = 7) {
  const observations = await call({ type: 'history', location: locationParams(location), days });
  return observations.map(revive);
}
