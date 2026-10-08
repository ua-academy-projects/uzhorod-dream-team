/**
 * Scheduler: a separate process that periodically calls the History service's
 * fetch endpoint. It knows nothing about the weather API or the database.
 */
import 'dotenv/config';
import { startScheduler, createTriggerFetch, DEFAULT_CRON_SCHEDULE } from './scheduler.js';

const HISTORY_SERVICE_URL = process.env.HISTORY_SERVICE_URL || 'http://localhost:3001';
const CRON_SCHEDULE = process.env.CRON_SCHEDULE || DEFAULT_CRON_SCHEDULE;
const TRIGGER_TOKEN = process.env.TRIGGER_TOKEN || '';

const triggerFetch = createTriggerFetch({ historyUrl: HISTORY_SERVICE_URL, token: TRIGGER_TOKEN });

try {
  // The startup run has a short delay so the History service can come up when started together
  startScheduler({ schedule: CRON_SCHEDULE, task: triggerFetch });
} catch (err) {
  console.error(err.message);
  process.exit(1);
}
console.log(`Scheduler started: "${CRON_SCHEDULE}" -> POST ${HISTORY_SERVICE_URL}/api/weather/fetch`);
