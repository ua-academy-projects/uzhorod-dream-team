import 'dotenv/config';

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function number(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const value = Number(raw);
  if (Number.isNaN(value)) throw new Error(`Environment variable ${name} must be a number`);
  return value;
}

const config = {
  port: number('PORT', 3001),
  databaseUrl: process.env.DATABASE_URL,
  amqpUrl: process.env.AMQP_URL || 'amqp://guest:guest@localhost:5672',
  redisUrl: process.env.REDIS_URL || 'redis://localhost:6379',
  triggerToken: process.env.TRIGGER_TOKEN || '',
  catchUpOnStart: process.env.CATCH_UP_ON_START !== 'false',
  initialBackfillDays: number('INITIAL_BACKFILL_DAYS', 30),
  location: {
    name: process.env.LOCATION_NAME || 'Berlin',
    latitude: number('LATITUDE', 52.52),
    longitude: number('LONGITUDE', 13.41),
  },
};

export function requireDatabaseUrl() {
  return required('DATABASE_URL');
}

export default config;
