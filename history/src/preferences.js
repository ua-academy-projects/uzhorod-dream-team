
import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import { cache } from './cache.js';
import { BadRequestError, asyncHandler } from './routes.js';

export const THEMES = ['light', 'dark'];
const COOKIE = 'uid';
const TTL_SECONDS = 365 * 24 * 3600;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function readUid(cookieHeader = '') {
  for (const part of cookieHeader.split(';')) {
    const [name, ...rest] = part.trim().split('=');
    if (name === COOKIE) {
      const value = rest.join('=');
      return UUID_RE.test(value) ? value : null;
    }
  }
  return null;
}

export const isTheme = (value) => THEMES.includes(value);

function identify(req, res, next) {
  let uid = readUid(req.headers.cookie);
  if (!uid) {
    uid = randomUUID();
    res.cookie(COOKIE, uid, { maxAge: TTL_SECONDS * 1000, httpOnly: true, sameSite: 'lax', path: '/' });
  }
  req.uid = uid;
  next();
}

const key = (uid) => `prefs:${uid}`;

const router = Router();
router.use(identify);

router.get(
  '/',
  asyncHandler(async (req, res) => {
    // Without the cache the UI falls back to the system theme instead of showing an error
    if (!cache.isReady) return res.json({ theme: null });
    const prefs = await cache.hGetAll(key(req.uid));
    res.json({ theme: isTheme(prefs.theme) ? prefs.theme : null });
  }),
);

router.put(
  '/',
  asyncHandler(async (req, res) => {
    const theme = req.body?.theme;
    if (!isTheme(theme)) throw new BadRequestError(`"theme" must be one of: ${THEMES.join(', ')}`);
    if (!cache.isReady) return res.status(503).json({ error: 'Preferences storage is unavailable' });
    // TTL is renewed on every save, so preferences of active browsers never expire
    await cache.multi().hSet(key(req.uid), { theme }).expire(key(req.uid), TTL_SECONDS).exec();
    res.json({ theme });
  }),
);

export default router;
