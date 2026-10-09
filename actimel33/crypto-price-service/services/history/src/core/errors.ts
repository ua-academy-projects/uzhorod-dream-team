/**
 * Errors carrying an HTTP status. `expose` decides whether the text leaves the
 * process: infrastructure failures stay in the log, the user gets a general phrase.
 */
export class AppError extends Error {
  readonly status: number;
  readonly expose: boolean;
  readonly publicMessage: string;

  constructor(message: string, status: number, expose: boolean, publicMessage?: string) {
    super(message);
    this.name = new.target.name;
    this.status = status;
    this.expose = expose;
    this.publicMessage = publicMessage ?? message;
  }
}

/** There is no data at all and none can be obtained right now. */
export class NoDataError extends AppError {
  constructor(message: string) {
    super(message, 503, true);
  }
}

/** Invalid request parameters. */
export class BadRequestError extends AppError {
  constructor(message: string) {
    super(message, 400, true);
  }
}

/** No such coin or currency — a permanent state that a retry will not fix. */
export class NotFoundError extends AppError {
  constructor(message: string) {
    super(message, 404, true);
  }
}

/** The upstream price source failed. Our service is fine, the source is not. */
export class UpstreamError extends AppError {
  constructor(message: string) {
    super(message, 502, true);
  }
}

/** The database is unreachable: an infrastructure outage, not a bad query. */
export class DbUnavailableError extends AppError {
  constructor(message: string) {
    super(message, 503, false, 'the database is temporarily unavailable');
  }
}

/** The only safe way to get text out of a caught value. */
export function errorMessage(err: unknown): string {
  if (err instanceof Error) return err.message;
  if (typeof err === 'string') return err;
  return String(err);
}
