import session from 'express-session';
import { RedisStore } from 'connect-redis';
import connectPgSimple from 'connect-pg-simple';
import type { RequestHandler } from 'express';
import { config } from '../config.ts';
import { pool } from '../db/pool.ts';
import { redis } from '../redis.ts';

const COOKIE_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;

/** What a visitor keeps between visits. Grows here if more settings appear. */
export type SessionPreferences = {
  theme?: 'light' | 'dark' | 'system';
};

declare module 'express-session' {
  interface SessionData {
    preferences?: SessionPreferences;
  }
}

/** Redis, or the session table of 004_sessions.sql with BACKEND=postgres. */
async function sessionStore(): Promise<session.Store> {
  if (config.backend === 'postgres') {
    const PgStore = connectPgSimple(session);
    return new PgStore({ pool, tableName: 'session' });
  }
  return new RedisStore({ client: await redis(), prefix: 'session:' });
}

/**
 * Sessions live outside the process: the UI keeps its theme even after this
 * service restarts, and a second instance would see the same data. The cookie
 * carries only the identifier.
 */
export async function sessionMiddleware(): Promise<RequestHandler> {
  return session({
    store: await sessionStore(),
    secret: config.sessionSecret,
    resave: false,
    // true, not false: the cookie is handed out on the very first visit rather
    // than only after something is written. Without it a visitor stays without
    // an identifier until the first theme click, and any hiccup on that request
    // leaves them with no session at all.
    saveUninitialized: true,
    cookie: {
      httpOnly: true,
      sameSite: 'lax',
      maxAge: COOKIE_MAX_AGE_MS,
      // No TLS in this environment, so the cookie cannot be secure-only.
      secure: false,
    },
  });
}
