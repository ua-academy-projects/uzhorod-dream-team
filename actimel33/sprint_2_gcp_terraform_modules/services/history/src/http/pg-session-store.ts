import session from 'express-session';
import type { SessionData } from 'express-session';
import { query } from '../db/pool.ts';
import { errorMessage } from '../core/errors.ts';

type Callback = (err?: unknown) => void;

// Expired rows are never served; pruning only keeps the table small.
const PRUNE_MS = 15 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

/** Each preference is its own key (theme => dark); the cookie metadata sits under "cookie". */
function toPairs(sess: SessionData): Record<string, string> {
  const pairs: Record<string, string> = { cookie: JSON.stringify(sess.cookie) };
  for (const [key, value] of Object.entries(sess.preferences ?? {})) {
    if (value !== undefined) pairs[key] = String(value);
  }
  return pairs;
}

function toSession(data: Record<string, string>): SessionData {
  const { cookie, ...preferences } = data;
  return { cookie: JSON.parse(cookie ?? '{}'), preferences } as SessionData;
}

const expiresAt = (sess: SessionData): Date =>
  sess.cookie?.expires ? new Date(sess.cookie.expires) : new Date(Date.now() + DAY_MS);

/** express-session store on the hstore key-value extension (005_session_hstore.sql). */
export class HstoreStore extends session.Store {
  constructor() {
    super();
    setInterval(() => {
      query('DELETE FROM session WHERE expire < now()').catch((err: unknown) => {
        console.error(`[history] session prune failed: ${errorMessage(err)}`);
      });
    }, PRUNE_MS).unref();
  }

  override get(sid: string, cb: (err: unknown, sess?: SessionData | null) => void): void {
    query<{ data: Record<string, string> }>(
      'SELECT hstore_to_json(data) AS data FROM session WHERE sid = $1 AND expire > now()',
      [sid],
    )
      .then(({ rows }) => cb(null, rows[0] ? toSession(rows[0].data) : null))
      .catch((err: unknown) => cb(err));
  }

  override set(sid: string, sess: SessionData, cb?: Callback): void {
    const pairs = toPairs(sess);
    query(
      `INSERT INTO session (sid, data, expire) VALUES ($1, hstore($2::text[], $3::text[]), $4)
       ON CONFLICT (sid) DO UPDATE SET data = EXCLUDED.data, expire = EXCLUDED.expire`,
      [sid, Object.keys(pairs), Object.values(pairs), expiresAt(sess)],
    )
      .then(() => cb?.())
      .catch((err: unknown) => cb?.(err));
  }

  override destroy(sid: string, cb?: Callback): void {
    query('DELETE FROM session WHERE sid = $1', [sid])
      .then(() => cb?.())
      .catch((err: unknown) => cb?.(err));
  }

  override touch(sid: string, sess: SessionData, cb?: Callback): void {
    query('UPDATE session SET expire = $2 WHERE sid = $1', [sid, expiresAt(sess)])
      .then(() => cb?.())
      .catch((err: unknown) => cb?.(err));
  }
}
