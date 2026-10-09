export type Latest = {
  coin: string;
  vs: string;
  price: number;
  observedAt: string;
  source: 'cache' | 'live';
  stale: boolean;
  staleReason?: string;
};

export type HistoryPoint = { price: number; observedAt: string };

export type History = {
  coin: string;
  vs: string;
  from: string;
  to: string;
  points: HistoryPoint[];
};

/** The caller needs the status: 503 means "no data yet", not a breakage. */
export class ApiError extends Error {
  readonly status: number;
  constructor(message: string, status: number) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let res: Response;
  try {
    // credentials: the session cookie identifies the visitor.
    res = await fetch(`/api${path}`, { credentials: 'same-origin', ...init });
  } catch {
    throw new ApiError('The history service is not responding', 0);
  }
  if (!res.ok) {
    const body = (await res.json().catch(() => ({}))) as { error?: string };
    throw new ApiError(body.error ?? `The service responded ${res.status}`, res.status);
  }
  return (await res.json()) as T;
}

export type Theme = 'light' | 'dark' | 'system';

export const getLatest = (): Promise<Latest> => request<Latest>('/price/latest');
export const getHistory = (): Promise<History> => request<History>('/price/history');
/** Returns once the request is queued; the new price arrives on a later read. */
export const refreshPrice = (): Promise<{ queued: boolean }> =>
  request<{ queued: boolean }>('/refresh', { method: 'POST' });

export const getTheme = (): Promise<{ theme: Theme }> => request<{ theme: Theme }>('/session');

export const saveTheme = (theme: Theme): Promise<{ theme: Theme }> =>
  request<{ theme: Theme }>('/session/theme', {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ theme }),
  });
