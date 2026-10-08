import { test } from 'node:test';
import assert from 'node:assert/strict';
import { describeWeatherCode } from '../src/weatherCodes.js';

test('describeWeatherCode', () => {
  assert.equal(describeWeatherCode(0), 'Clear sky');
  assert.equal(describeWeatherCode(42), 'Unknown (42)');
  assert.equal(describeWeatherCode(null), null);
});
