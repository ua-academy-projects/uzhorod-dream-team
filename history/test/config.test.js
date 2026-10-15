import { test } from 'node:test';
import assert from 'node:assert/strict';
import { boolean } from '../src/config.js';

test('boolean reads true/false values and falls back when unset', (t) => {
  const name = 'TEST_BOOLEAN_FLAG';
  t.after(() => delete process.env[name]);
  for (const [raw, want] of [['true', true], ['TRUE', true], ['1', true], ['yes', true], ['false', false], [' False ', false], ['0', false], ['no', false]]) {
    process.env[name] = raw;
    assert.equal(boolean(name, !want), want, raw);
  }
  process.env[name] = '';
  assert.equal(boolean(name, true), true);
  delete process.env[name];
  assert.equal(boolean(name, false), false);
});

test('boolean rejects a typo instead of silently using the default', (t) => {
  const name = 'TEST_BOOLEAN_FLAG';
  t.after(() => delete process.env[name]);
  process.env[name] = 'flase';
  assert.throws(() => boolean(name, true), /must be true or false/);
});
