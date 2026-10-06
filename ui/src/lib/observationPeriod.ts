import { subDays } from 'date-fns';
import type { ObservationPeriod } from '../types/api';

export function observationRange(period: ObservationPeriod, now: Date) {
  if (period.kind === 'custom') return { from: new Date(period.from), to: new Date(period.to) };
  return { from: subDays(now, period.days), to: now };
}
