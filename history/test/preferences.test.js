import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isTheme, readUid } from '../src/preferences.js';

const uid = '3f2b8c1e-9a4d-4e6f-8b2a-1c3d5e7f9a0b';

test('readUid finds the uid cookie among others', () => {
  assert.equal(readUid(`a=1; uid=${uid}; b=2`), uid);
  assert.equal(readUid(`uid=${uid}`), uid);
});

test('readUid rejects missing or malformed ids', () => {
  assert.equal(readUid(), null);
  assert.equal(readUid('a=1'), null);
  assert.equal(readUid('uid=not-a-uuid'), null);
  assert.equal(readUid('xuid=' + uid), null);
});

test('isTheme accepts only light and dark', () => {
  assert.equal(isTheme('light'), true);
  assert.equal(isTheme('dark'), true);
  assert.equal(isTheme('blue'), false);
  assert.equal(isTheme(undefined), false);
});
