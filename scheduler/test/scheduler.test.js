import { test, mock, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { startScheduler, createTriggerFetch, DEFAULT_CRON_SCHEDULE } from '../scheduler.js';

const HOUR = 3_600_000;
let stop;

afterEach(() => {
  stop?.();
  stop = undefined;
  mock.timers.reset();
});

// Fake clock: the test "waits" hours instantly. Starts at 10:30 local time.
function fakeClock() {
  const start = new Date();
  start.setHours(10, 30, 0, 0);
  mock.timers.enable({ apis: ['setTimeout', 'Date'], now: start });
}

// node-cron re-arms a 1-second timer on every check, and the mock clock does not run timers
// created during a tick, so time must be advanced in 1-second steps.
function advance(ms) {
  for (let elapsed = 0; elapsed < ms; elapsed += 1000) mock.timers.tick(1000);
}

test('default schedule is hourly', () => {
  assert.equal(DEFAULT_CRON_SCHEDULE, '0 * * * *');
});

test('task runs once at startup and then at the top of every hour', () => {
  fakeClock();
  const runs = [];
  stop = startScheduler({ task: () => runs.push(new Date()), startupDelayMs: 3000 });

  mock.timers.tick(3000);
  assert.equal(runs.length, 1, 'startup run');

  advance(HOUR * 3); // 10:30:03 -> 13:30:03: expect 11:00, 12:00, 13:00
  assert.equal(runs.length, 4);
  assert.deepEqual(
    runs.slice(1).map((d) => [d.getHours(), d.getMinutes()]),
    [[11, 0], [12, 0], [13, 0]],
  );
});

test('nothing runs between the full hours', () => {
  fakeClock();
  let calls = 0;
  stop = startScheduler({ task: () => calls++, startupDelayMs: 1000 });

  mock.timers.tick(1000);
  advance(29 * 60_000); // up to 10:59:01
  assert.equal(calls, 1, 'only the startup run so far');
});

test('stopping the scheduler stops the runs', () => {
  fakeClock();
  let calls = 0;
  stop = startScheduler({ task: () => calls++, startupDelayMs: 1000 });
  mock.timers.tick(1000);
  stop();
  advance(HOUR * 2);
  assert.equal(calls, 1);
});

test('invalid cron expression is rejected', () => {
  assert.throws(() => startScheduler({ schedule: 'not a cron', task() {} }), /Invalid CRON_SCHEDULE/);
});

test('triggerFetch POSTs to the History service with the token', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    return { ok: true, json: async () => ({ observedAt: 'x', temperature: 1, conditions: 'Clear sky' }) };
  };
  const log = { log() {}, error() {} };
  await createTriggerFetch({ historyUrl: 'http://h:3001', token: 'secret', fetchImpl, log })();

  assert.equal(calls[0].url, 'http://h:3001/api/weather/fetch');
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(calls[0].options.headers['X-Trigger-Token'], 'secret');
});

test('triggerFetch logs an error instead of throwing when History is unreachable', async () => {
  const errors = [];
  const fetchImpl = async () => { throw new Error('ECONNREFUSED'); };
  await createTriggerFetch({ historyUrl: 'http://h', fetchImpl, log: { log() {}, error: (m) => errors.push(m) } })();
  assert.match(errors[0], /Could not reach History service/);
});
