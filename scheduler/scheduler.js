/**
 * Scheduling logic, separate from index.js so it can be tested without side effects.
 */
import cron from 'node-cron';

export const DEFAULT_CRON_SCHEDULE = '0 * * * *'; // every hour, at minute 0

/**
 * Runs `task` on the cron schedule, and once shortly after start.
 * Throws if the schedule is invalid. Returns a function that stops the cron job.
 */
export function startScheduler({ schedule = DEFAULT_CRON_SCHEDULE, task, startupDelayMs = 3000 }) {
  if (!cron.validate(schedule)) throw new Error(`Invalid CRON_SCHEDULE: "${schedule}"`);

  const job = cron.schedule(schedule, task);
  const startupTimer = setTimeout(task, startupDelayMs);
  return () => {
    job.stop();
    clearTimeout(startupTimer);
  };
}

/** Builds the function that asks the History service to fetch the current weather. */
export function createTriggerFetch({ historyUrl, token = '', fetchImpl = fetch, log = console }) {
  const url = `${historyUrl}/api/weather/fetch`;
  return async function triggerFetch() {
    const stamp = `[${new Date().toISOString()}]`;
    try {
      const response = await fetchImpl(url, {
        method: 'POST',
        headers: token ? { 'X-Trigger-Token': token } : {},
        signal: AbortSignal.timeout(30_000),
      });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        log.error(`${stamp} Fetch trigger failed (${response.status}): ${body.error ?? ''}`);
        return;
      }
      log.log(`${stamp} Stored observation @ ${body.observedAt}: ${body.temperature}°C, ${body.conditions}`);
    } catch (err) {
      log.error(`${stamp} Could not reach History service at ${url}: ${err.message}`);
    }
  };
}
