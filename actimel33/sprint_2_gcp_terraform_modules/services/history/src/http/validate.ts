import { BadRequestError } from '../core/errors.ts';

const ASSET_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;

/** An empty parameter falls back to the default. A non-empty but malformed one is an error, not a silent substitution. */
export function asset(value: unknown, fallback: string, field: string): string {
  if (value === undefined || value === '') return fallback;
  if (typeof value !== 'string') throw new BadRequestError(`invalid '${field}': expected a string`);
  const normalized = value.toLowerCase();
  if (!ASSET_RE.test(normalized)) {
    throw new BadRequestError(`invalid '${field}': expected [a-z0-9-], got "${value}"`);
  }
  return normalized;
}

export function isoDate(value: unknown, fallback: Date, field: string): Date {
  if (value === undefined || value === '') return fallback;
  if (typeof value !== 'string') throw new BadRequestError(`invalid '${field}': expected a string`);
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    throw new BadRequestError(`invalid '${field}': expected ISO date, got "${value}"`);
  }
  return parsed;
}

export function boundedInt(value: unknown, fallback: number, max: number, field: string): number {
  if (value === undefined || value === '') return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > max) {
    throw new BadRequestError(`invalid '${field}': expected integer 1..${max}, got "${value}"`);
  }
  return parsed;
}
