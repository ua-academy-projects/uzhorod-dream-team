import pg from 'pg';
import type { QueryResult, QueryResultRow } from 'pg';
import { config } from '../config.ts';
import { DbUnavailableError, errorMessage } from '../core/errors.ts';

export const pool = new pg.Pool({
  connectionString: config.databaseUrl,
  max: 10,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
});

// Without this handler a dropped idle connection takes the whole process down.
pool.on('error', (err: unknown) => {
  console.error(`[history] idle client error: ${errorMessage(err)}`);
});

// Network codes and the Postgres 08 / 57P classes mean a temporary outage, not a bad query.
const CONNECTION_CODES = new Set([
  'ECONNREFUSED', 'ENOTFOUND', 'ETIMEDOUT', 'ECONNRESET', 'EHOSTUNREACH', 'EPIPE',
  '08000', '08001', '08003', '08004', '08006', '08007', '57P01', '57P02', '57P03',
]);

function isConnectionFailure(err: unknown): boolean {
  const code = (err as { code?: string } | null)?.code;
  if (code !== undefined && CONNECTION_CODES.has(code)) return true;
  const message = errorMessage(err);
  return /connection terminated|timeout exceeded when trying to connect/i.test(message);
}

/** The single entry point to the database: tells "database is down" (503) from a bad query (500). */
export async function query<R extends QueryResultRow = QueryResultRow>(
  text: string,
  values?: unknown[],
): Promise<QueryResult<R>> {
  try {
    return await pool.query<R>(text, values);
  } catch (err) {
    if (isConnectionFailure(err)) {
      throw new DbUnavailableError(`database unavailable: ${errorMessage(err)}`);
    }
    throw err;
  }
}

/** Whether the database is alive right now. Used by /health, so it never throws. */
export async function isDbAlive(): Promise<boolean> {
  try {
    await pool.query('SELECT 1');
    return true;
  } catch (err) {
    console.error(`[history] db check failed: ${errorMessage(err)}`);
    return false;
  }
}
