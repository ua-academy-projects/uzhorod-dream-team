import express from 'express';
import type { NextFunction, Request, Response } from 'express';
import { AppError } from '../core/errors.ts';
import { healthRoutes } from './routes/health.ts';
import { priceRoutes } from './routes/price.ts';
import { sessionRoutes } from './routes/session.ts';
import { sessionMiddleware } from './session.ts';

type HttpError = Error & { status?: number };

export async function createApp() {
  const app = express();
  app.use(express.json({ limit: '1mb' }));

  // Health must answer even if sessions cannot start, so it goes first.
  app.use(healthRoutes);
  app.use(await sessionMiddleware());
  app.use(priceRoutes);
  app.use(sessionRoutes);

  app.use((_req: Request, res: Response) => {
    res.status(404).json({ error: 'not found' });
  });

  app.use((err: HttpError, _req: Request, res: Response, _next: NextFunction) => {
    const status = err.status ?? 500;
    if (status >= 500) {
      console.error(`[history] ${err.name}: ${err.message}`);
    }
    // Only text explicitly marked as public leaves the process. The rest stays in the log.
    const body = err instanceof AppError && !err.expose ? err.publicMessage
      : err instanceof AppError ? err.message
      : 'internal error';
    res.status(status).json({ error: body });
  });

  return app;
}
