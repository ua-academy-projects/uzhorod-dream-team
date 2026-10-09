import { useEffect } from 'react';

/** How long to wait before checking whether a queued update has landed. */
const RECHECK_MS = 4000;

/**
 * Stale means an update is already queued, so the data should become fresh by
 * itself. This looks again shortly after, letting the banner disappear without
 * the visitor pressing anything.
 */
export function useStaleWatch(stale: boolean | undefined, recheck: () => void): void {
  useEffect(() => {
    if (!stale) return undefined;
    const timer = setTimeout(recheck, RECHECK_MS);
    return () => clearTimeout(timer);
  }, [stale, recheck]);
}
