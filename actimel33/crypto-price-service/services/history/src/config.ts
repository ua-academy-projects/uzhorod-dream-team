const required = (name: string): string => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env: ${name}`);
  return value;
};

const num = (name: string, fallback: number): number => {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) {
    throw new Error(`Env ${name} must be a number, got "${raw}"`);
  }
  return parsed;
};

const QUEUE_DRIVERS = ['redis', 'postgres'] as const;
export type QueueDriver = (typeof QUEUE_DRIVERS)[number];

const queueDriver = (): QueueDriver => {
  const raw = process.env.QUEUE_DRIVER || 'redis';
  if (!(QUEUE_DRIVERS as readonly string[]).includes(raw)) {
    throw new Error(`Env QUEUE_DRIVER must be one of ${QUEUE_DRIVERS.join(', ')}, got "${raw}"`);
  }
  return raw as QueueDriver;
};

export const config = {
  port: num('HISTORY_PORT', 3001),
  // Loopback by default. On a dedicated VM the peers live elsewhere,
  // so the address is configurable rather than hard-coded.
  host: process.env.HISTORY_HOST ?? '127.0.0.1',
  databaseUrl: required('DATABASE_URL'),
  queueDriver: queueDriver(),
  redisUrl: process.env.REDIS_URL ?? 'redis://localhost:6379',
  redisPassword: required('REDIS_PASSWORD'),
  sessionSecret: required('SESSION_SECRET'),
  cacheTtlMs: num('CACHE_TTL_SECONDS', 900) * 1000,
  bootstrapDays: num('BOOTSTRAP_DAYS', 7),
  defaultCoin: process.env.DEFAULT_COIN ?? 'bitcoin',
  defaultVs: process.env.DEFAULT_VS ?? 'usd',
} as const;
