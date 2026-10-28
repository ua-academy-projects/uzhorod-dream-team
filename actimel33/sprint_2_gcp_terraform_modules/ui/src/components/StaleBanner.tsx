import { formatClock } from './format.ts';

type Props = {
  observedAt: string;
  reason?: string;
};

/**
 * Shown while the stored price is older than the cache window. With a queue in
 * place this is the normal in-between state, not a failure: a request is already
 * on its way, so the wording stays neutral. Colour alone carries no meaning —
 * the reason is always spelled out next to it.
 */
export function StaleBanner({ observedAt, reason }: Props) {
  return (
    <div className="stale" role="status">
      <span className="stale__mark" aria-hidden="true">↻</span>
      <p>
        Showing the last known price from {formatClock(observedAt)}
        {reason ? ` — ${reason}` : ''}.
      </p>
    </div>
  );
}
