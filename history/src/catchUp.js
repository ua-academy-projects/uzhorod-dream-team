/**
 * How many days of hourly history must be fetched to fill the gap since the last stored observation.
 * Pure function (no database, no network) so it can be unit-tested.
 *
 * @param {Date|null} latest  observedAt of the newest stored row, or null if there is none
 * @param {Date} now
 * @param {{ initialDays: number, maxDays: number }} limits
 * @returns {number} 0 when the data is fresh, otherwise 1..maxDays
 */
export function daysToCatchUp(latest, now, { initialDays, maxDays }) {
  if (!latest) return Math.min(initialDays, maxDays);
  const gapHours = (now.getTime() - latest.getTime()) / 3_600_000;
  if (gapHours < 1) return 0; // the newest hour is already stored
  return Math.min(Math.ceil(gapHours / 24), maxDays);
}

/**
 * Runs `task` until it succeeds, with exponential backoff between attempts.
 * Never throws: after the last failed attempt it logs and gives up.
 */
export async function withRetries(task, { attempts = 10, initialDelayMs = 2000, maxDelayMs = 60_000, log = console } = {}) {
  let delay = initialDelayMs;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await task();
    } catch (err) {
      if (attempt === attempts) {
        log.error(`Catch-up failed after ${attempts} attempts: ${err.message}`);
        return null;
      }
      log.warn(`Catch-up attempt ${attempt}/${attempts} failed: ${err.message}. Retrying in ${delay / 1000}s`);
      await new Promise((resolve) => setTimeout(resolve, delay));
      delay = Math.min(delay * 2, maxDelayMs);
    }
  }
  return null;
}
