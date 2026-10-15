import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PendingRequests, parseReply } from '../src/broker/pending.js';

test('a reply settles the request with the same correlationId', async () => {
  const pending = new PendingRequests();
  const a = pending.add('a', 1000);
  const b = pending.add('b', 1000);
  assert.equal(pending.settle('b', { ok: true, data: 'B' }), true);
  assert.equal(pending.settle('a', { ok: true, data: 'A' }), true);
  assert.deepEqual(await a, { ok: true, data: 'A' });
  assert.deepEqual(await b, { ok: true, data: 'B' });
  assert.equal(pending.size, 0);
});

test('a reply nobody waits for is reported, not delivered', () => {
  const pending = new PendingRequests();
  assert.equal(pending.settle('unknown', { ok: true }), false);
});

test('a request without a reply times out and is forgotten', async () => {
  const pending = new PendingRequests();
  await assert.rejects(pending.add('slow', 5), /no reply from the Fetcher within/);
  assert.equal(pending.size, 0);
  assert.equal(pending.settle('slow', { ok: true }), false); // a late reply is dropped
});

test('a request that could not be sent is rejected right away', async () => {
  const pending = new PendingRequests();
  const reply = pending.add('a', 1000);
  pending.fail('a', new Error('send failed'));
  await assert.rejects(reply, /send failed/);
  assert.equal(pending.size, 0);
});

test('parseReply accepts reply objects and JSON, rejects anything else', () => {
  assert.deepEqual(parseReply('{"ok":true,"data":1}'), { ok: true, data: 1 });
  assert.deepEqual(parseReply({ ok: false, error: 'x', kind: 'upstream' }), { ok: false, error: 'x', kind: 'upstream' });
  for (const raw of ['not json', '[]', null, { data: 1 }]) {
    assert.equal(parseReply(raw).kind, 'internal');
  }
});
