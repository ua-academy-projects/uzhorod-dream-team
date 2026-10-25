/**
 * Errors carrying an HTTP status. `publicMessage` is what leaves the process:
 * infrastructure failures stay in the log, the user gets a general phrase.
 */
export class AppError extends Error {
  readonly status: number;
  readonly publicMessage: string;

  constructor(message: string, status: number, publicMessage?: string) {
    super(message);
    this.name = new.target.name;
    this.status = status;
    this.publicMessage = publicMessage ?? message;
  }
}

/** There is no data at all and none can be obtained right now. */
export class NoDataError extends AppError {
  constructor(message: string) {
    super(message, 503);
  }
}

/** Invalid request parameters. */
export class BadRequestError extends AppError {
  constructor(message: string) {
    super(message, 400);
  }
}

/** A coin or currency this service does not track. */
export class NotFoundError extends AppError {
  constructor(message: string) {
    super(message, 404);
  }
}

/** The database is unreachable: an infrastructure outage, not a bad query. */
export class DbUnavailableError extends AppError {
  constructor(message: string) {
    super(message, 503, 'the database is temporarily unavailable');
  }
}

/** The only safe way to get text out of a caught value. */
export function errorMessage(err: unknown): string {
  if (err instanceof Error) return err.message;
  if (typeof err === 'string') return err;
  return String(err);
}
