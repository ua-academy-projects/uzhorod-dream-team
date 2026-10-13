import { useCallback, useEffect, useRef, useState } from 'react';
import { ApiError, getHistory, getLatest, refreshPrice } from '../api/client.ts';
import { useStaleWatch } from './use-stale-watch.ts';
import type { HistoryPoint, Latest } from '../api/client.ts';

export type Status = 'loading' | 'ready' | 'empty' | 'error';

/** How long to wait before re-reading after queueing a refresh. */
const REFRESH_SETTLE_MS = 2500;

export type PriceState = {
  status: Status;
  latest: Latest | null;
  points: HistoryPoint[];
  error: string | null;
  refreshing: boolean;
  refresh: () => void;
  retry: () => void;
};

const message = (err: unknown, fallback: string): string =>
  err instanceof Error ? err.message : fallback;

export function usePrice(): PriceState {
  const [status, setStatus] = useState<Status>('loading');
  const [latest, setLatest] = useState<Latest | null>(null);
  const [points, setPoints] = useState<HistoryPoint[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const inFlight = useRef(false);

  /** Reads the price and the chart together; the screen state is the caller's business. */
  const read = useCallback(async () => {
    const [current, history] = await Promise.all([getLatest(), getHistory()]);
    setLatest(current);
    setPoints(history.points);
  }, []);

  const load = useCallback(async () => {
    if (inFlight.current) return;
    inFlight.current = true;
    setStatus('loading');
    setError(null);
    try {
      await read();
      setStatus('ready');
    } catch (err) {
      // 503 is "nothing yet" (a request is queued) or "database down":
      // not a broken page, and the server's text says which.
      if (err instanceof ApiError && err.status === 503) {
        setError(err.message);
        setStatus('empty');
        return;
      }
      setError(message(err, 'Unknown error'));
      setStatus('error');
    } finally {
      inFlight.current = false;
    }
  }, [read]);

  useEffect(() => {
    void load();
  }, [load]);

  const refresh = useCallback(async () => {
    if (inFlight.current) return;
    inFlight.current = true;
    setRefreshing(true);
    setError(null);
    try {
      // The request only gets queued; the fetcher answers through the queue,
      // so the new price appears on a later read rather than in this response.
      await refreshPrice();
      await new Promise((resolve) => setTimeout(resolve, REFRESH_SETTLE_MS));
      await read();
    } catch (err) {
      // The price already on screen stays; only the failure is reported.
      setError(message(err, 'Refresh failed'));
    } finally {
      inFlight.current = false;
      setRefreshing(false);
    }
  }, [read]);

  /** Re-reads without flipping the screen back to the loading state. */
  const recheck = useCallback(() => {
    read().catch(() => {
      /* the data already on screen stays */
    });
  }, [read]);

  useStaleWatch(latest?.stale, recheck);

  return {
    status, latest, points, error, refreshing,
    refresh: () => void refresh(),
    retry: () => void load(),
  };
}
