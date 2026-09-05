import { test } from 'node:test';
import assert from 'node:assert/strict';
import { keypair, signRecord, verifyRecord, canonical } from '../lib/sign.js';
import { record } from './fx.js';

test('canonical json sorts keys', () => assert.equal(canonical({ b: 1, a: { d: 2, c: [3] } }), '{"a":{"c":[3],"d":2},"b":1}'));

test('sign then verify; server fields do not affect the signature', () => {
  const r = record();
  assert.ok(verifyRecord(r));
  assert.ok(verifyRecord({ ...r, verified: { ok: 3, fail: 0, versions: [] }, tier: 'community', quarantined: false }));
});

test('forgery fails: wrong key, altered field, garbage key', () => {
  const r = record();
  const other = keypair();
  assert.ok(!verifyRecord({ ...r, sig: signRecord(r, other.privateKey) }));
  assert.ok(!verifyRecord({ ...r, target: '객실' }));
  assert.ok(!verifyRecord({ ...r, publisher: 'bm90IGEga2V5' }));
});
