const required = (name: string): string => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env: ${name}`);
  return value;
};

const num = (name: string, fallback: number): number => {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`Env ${name} must be a positive number, got "${raw}"`);
  }
  return parsed;
};

// Where the queue and the sessions live: Redis, or Postgres for everything.
const BACKENDS = ['redis', 'postgres'] as const;
export type Backend = (typeof BACKENDS)[number];

const backendFromEnv = (): Backend => {
  const raw = process.env.BACKEND || 'redis';
  if (!(BACKENDS as readonly string[]).includes(raw)) {
    throw new Error(`Env BACKEND must be one of ${BACKENDS.join(', ')}, got "${raw}"`);
  }
  return raw as Backend;
};

const backend = backendFromEnv();

export const config = {
  port: num('HISTORY_PORT', 3001),
  // Loopback by default. On a dedicated VM the peers live elsewhere,
  // so the address is configurable rather than hard-coded.
  host: process.env.HISTORY_HOST ?? '127.0.0.1',
  databaseUrl: required('DATABASE_URL'),
  backend,
  redisUrl: process.env.REDIS_URL ?? 'redis://localhost:6379',
  // Not used at all with BACKEND=postgres.
  redisPassword: backend === 'redis' ? required('REDIS_PASSWORD') : '',
  sessionSecret: required('SESSION_SECRET'),
  cacheTtlMs: num('CACHE_TTL_SECONDS', 900) * 1000,
  bootstrapDays: num('BOOTSTRAP_DAYS', 7),
  defaultCoin: process.env.DEFAULT_COIN ?? 'bitcoin',
  defaultVs: process.env.DEFAULT_VS ?? 'usd',
} as const;
