import { Router } from 'express';
import type { Request, Response } from 'express';
import { BadRequestError } from '../../core/errors.ts';
import type { SessionPreferences } from '../session.ts';

const THEMES = ['light', 'dark', 'system'] as const;
type Theme = (typeof THEMES)[number];

const isTheme = (value: unknown): value is Theme =>
  typeof value === 'string' && (THEMES as readonly string[]).includes(value);

export const sessionRoutes = Router();

sessionRoutes.get('/session', (req: Request, res: Response) => {
  const preferences: SessionPreferences = req.session.preferences ?? {};
  res.json({ theme: preferences.theme ?? 'system' });
});

sessionRoutes.put('/session/theme', (req: Request, res: Response) => {
  const { theme } = (req.body ?? {}) as { theme?: unknown };
  if (!isTheme(theme)) {
    throw new BadRequestError(`invalid 'theme': expected one of ${THEMES.join(', ')}`);
  }

  req.session.preferences = { ...req.session.preferences, theme };
  req.session.save((err) => {
    if (err) {
      console.error(`[history] saving session failed: ${err.message}`);
      res.status(503).json({ error: 'could not save the preference' });
      return;
    }
    res.json({ theme });
  });
});
