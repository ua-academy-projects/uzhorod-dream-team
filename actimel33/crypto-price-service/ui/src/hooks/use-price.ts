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

export function usePrice(): PriceState {
  const [status, setStatus] = useState<Status>('loading');
  const [latest, setLatest] = useState<Latest | null>(null);
  const [points, setPoints] = useState<HistoryPoint[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  // Whether the component is still mounted and the response is not stale:
  // StrictMode mounts effects twice in development.
  const alive = useRef(true);
  const inFlight = useRef(false);

  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  const load = useCallback(async () => {
    if (inFlight.current) return;
    inFlight.current = true;
    setStatus('loading');
    setError(null);
    try {
      const [current, history] = await Promise.all([getLatest(), getHistory()]);
      if (!alive.current) return;
      setLatest(current);
      setPoints(history.points);
      setStatus('ready');
    } catch (err) {
      if (!alive.current) return;
      // 503 means the database is empty and the source is unreachable:
      // that is "nothing yet", not a failure.
      if (err instanceof ApiError && err.status === 503) {
        setStatus('empty');
        return;
      }
      setError(err instanceof Error ? err.message : 'Unknown error');
      setStatus('error');
    } finally {
      inFlight.current = false;
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const refresh = useCallback(async () => {
    if (inFlight.current) return;
    inFlight.current = true;
    setRefreshing(true);
    try {
      // The request only gets queued; the fetcher answers through the queue,
      // so the new price appears on a later read rather than in this response.
      await refreshPrice();
      await new Promise((resolve) => setTimeout(resolve, REFRESH_SETTLE_MS));
      if (!alive.current) return;

      const [current, history] = await Promise.all([getLatest(), getHistory()]);
      if (!alive.current) return;
      setLatest(current);
      setPoints(history.points);
      setStatus('ready');
    } catch (err) {
      if (!alive.current) return;
      setError(err instanceof Error ? err.message : 'Refresh failed');
      setStatus('error');
    } finally {
      inFlight.current = false;
      if (alive.current) setRefreshing(false);
    }
  }, []);

  /** Re-reads without flipping the screen back to the loading state. */
  const recheck = useCallback(() => {
    Promise.all([getLatest(), getHistory()])
      .then(([current, history]) => {
        if (!alive.current) return;
        setLatest(current);
        setPoints(history.points);
      })
      .catch(() => {
        /* the data already on screen stays */
      });
  }, []);

  useStaleWatch(latest?.stale, recheck);

  return {
    status, latest, points, error, refreshing,
    refresh: () => void refresh(),
    retry: () => void load(),
  };
}
