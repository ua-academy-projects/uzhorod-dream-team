import { useEffect } from 'react';

/** How often to check whether a queued update has landed. */
const RECHECK_MS = 4000;

/**
 * Stale means an update is already queued, so the data should become fresh by
 * itself. This keeps looking until it does, letting the banner disappear
 * without the visitor pressing anything.
 */
export function useStaleWatch(stale: boolean | undefined, recheck: () => void): void {
  useEffect(() => {
    if (!stale) return undefined;
    const timer = setInterval(recheck, RECHECK_MS);
    return () => clearInterval(timer);
  }, [stale, recheck]);
}
