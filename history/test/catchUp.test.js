import { test } from 'node:test';
import assert from 'node:assert/strict';
import { daysToCatchUp, withRetries } from '../src/catchUp.js';

const limits = { initialDays: 30, maxDays: 92 };
const now = new Date('2026-09-30T12:00:00Z');
const hoursAgo = (h) => new Date(now.getTime() - h * 3_600_000);

test('empty database → initial backfill', () => {
  assert.equal(daysToCatchUp(null, now, limits), 30);
});

test('fresh data → nothing to do', () => {
  assert.equal(daysToCatchUp(hoursAgo(0.5), now, limits), 0);
});

test('gap is rounded up to whole days', () => {
  assert.equal(daysToCatchUp(hoursAgo(2), now, limits), 1);
  assert.equal(daysToCatchUp(hoursAgo(24), now, limits), 1);
  assert.equal(daysToCatchUp(hoursAgo(25), now, limits), 2);
});

test('gap is capped at maxDays', () => {
  assert.equal(daysToCatchUp(hoursAgo(24 * 200), now, limits), 92);
  assert.equal(daysToCatchUp(null, now, { initialDays: 500, maxDays: 92 }), 92);
});

test('withRetries retries until the task succeeds', async () => {
  let calls = 0;
  const log = { warn() {}, error() {} };
  const result = await withRetries(
    async () => {
      if (++calls < 3) throw new Error('fetcher down');
      return 'ok';
    },
    { attempts: 5, initialDelayMs: 1, maxDelayMs: 2, log },
  );
  assert.equal(result, 'ok');
  assert.equal(calls, 3);
});

test('withRetries gives up without throwing', async () => {
  const errors = [];
  const log = { warn() {}, error: (m) => errors.push(m) };
  const result = await withRetries(async () => { throw new Error('nope'); }, { attempts: 2, initialDelayMs: 1, log });
  assert.equal(result, null);
  assert.equal(errors.length, 1);
});
