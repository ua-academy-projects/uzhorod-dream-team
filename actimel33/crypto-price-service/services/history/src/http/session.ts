import session from 'express-session';
import { RedisStore } from 'connect-redis';
import type { RequestHandler } from 'express';
import { config } from '../config.ts';
import { redis } from '../queue/client.ts';

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

/**
 * Sessions live in Redis rather than in the process: the UI keeps its theme
 * even after this service restarts, and a second instance would see the same
 * data. The cookie carries only the identifier.
 */
export async function sessionMiddleware(): Promise<RequestHandler> {
  const client = await redis();
  return session({
    store: new RedisStore({ client, prefix: 'session:' }),
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
