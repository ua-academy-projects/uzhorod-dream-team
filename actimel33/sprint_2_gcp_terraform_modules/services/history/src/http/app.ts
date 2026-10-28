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
  app.disable('x-powered-by');
  // The only JSON body is {"theme": ...}.
  app.use(express.json({ limit: '1kb' }));

  // Health and prices need no session: they answer even if the session store
  // is down, and a price request does not leave a session behind.
  app.use(healthRoutes);
  app.use(priceRoutes);
  app.use(await sessionMiddleware());
  app.use(sessionRoutes);

  app.use((_req: Request, res: Response) => {
    res.status(404).json({ error: 'not found' });
  });

  app.use((err: HttpError, _req: Request, res: Response, next: NextFunction) => {
    if (res.headersSent) return next(err);
    const status = err.status ?? 500;
    if (status >= 500) {
      console.error(`[history] ${err.name}: ${err.message}`);
    }
    // 4xx (ours or the JSON parser's) explain the request; 5xx text stays in the log.
    const body = err instanceof AppError ? err.publicMessage
      : status < 500 ? err.message
      : 'internal error';
    res.status(status).json({ error: body });
  });

  return app;
}
