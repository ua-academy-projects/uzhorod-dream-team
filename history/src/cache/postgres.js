/**
 * Key-value cache in PostgreSQL, the counterpart of the Redis one.
 * cache_entries is a regular (logged) table with hstore values, so values are flat string pairs that survive a crash.
 * pg_cron deletes expired rows every minute; reads skip them meanwhile.
 */
import { sequelize } from '../db/index.js';
import { MAX_RECONNECT_DELAY_MS } from '../broker/pending.js';

const TTL_JOB = 'weather-cache-ttl';

let ready = false; // true once hstore, the table and the cleanup job exist
let retryDelay = 1000;

export const isReady = () => ready;

async function declare() {
  await sequelize.query('CREATE EXTENSION IF NOT EXISTS hstore');

  await sequelize.query(`
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_class WHERE relname = 'cache_entries' AND relnamespace = 'public'::regnamespace
                 AND relpersistence = 'u') THEN
        DROP TABLE cache_entries;
      END IF;
    END $$`);
  await sequelize.query(`
    CREATE TABLE IF NOT EXISTS cache_entries (
      key text PRIMARY KEY,
      value hstore NOT NULL,
      expires_at timestamptz
    )`);
  await sequelize.query('CREATE EXTENSION IF NOT EXISTS pg_cron');
  // Same job name: updates the existing job instead of adding another one
  await sequelize.query('SELECT cron.schedule($1, $2, $3)', {
    bind: [TTL_JOB, '* * * * *', 'DELETE FROM cache_entries WHERE expires_at < now()'],
  });
  // The job connects to cron.host as it was when the job was created; follow a later change of the setting
  await sequelize.query(
    `UPDATE cron.job SET nodename = current_setting('cron.host')
     WHERE jobname = $1 AND nodename IS DISTINCT FROM current_setting('cron.host')`,
    { bind: [TTL_JOB] },
  );
}

/** Creates hstore, the table and the cleanup job in the background, retrying until the database is there. */
export function connectCache() {
  declare()
    .then(() => {
      ready = true;
      console.log('PostgreSQL cache ready');
    })
    .catch((err) => {
      console.error(`PostgreSQL cache: ${err.message}. Retrying in ${retryDelay / 1000}s`);
      setTimeout(connectCache, retryDelay);
      retryDelay = Math.min(retryDelay * 2, MAX_RECONNECT_DELAY_MS);
    });
}

export async function get(key) {
  const [rows] = await sequelize.query(
    'SELECT hstore_to_json(value) AS value FROM cache_entries WHERE key = $1 AND (expires_at IS NULL OR expires_at > now())',
    { bind: [key] },
  );
  return rows[0]?.value ?? null;
}

// hstore holds only flat text pairs, so the value must be an object of strings
export async function set(key, value, ttlSeconds) {
  if (!Object.values(value).every((v) => typeof v === 'string')) {
    throw new TypeError(`cache value for "${key}" must be an object of strings`);
  }
  await sequelize.query(
    `INSERT INTO cache_entries (key, value, expires_at)
     VALUES ($1, hstore($2::text[], $3::text[]), now() + make_interval(secs => $4))
     ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, expires_at = EXCLUDED.expires_at`,
    { bind: [key, Object.keys(value), Object.values(value), ttlSeconds] },
  );
}
