import { test } from 'node:test';
import assert from 'node:assert/strict';
import telemetry from '../api/telemetry.js';
import { call } from './fx.js';

const post = body => call(telemetry, { method: 'POST', body });
const good = { ts: '2026-09-05T01:00:00.000Z', event: 'tool', fields: { tool: 'phone_tap', ok: true, ms: 120 } };

test('telemetry: POST only', async () => {
  assert.equal((await call(telemetry, { method: 'GET' })).code, 405);
});

test('telemetry: 400 on bad body', async () => {
  assert.equal((await post('{not json')).code, 400);
  assert.equal((await post({ ...good, ts: 'yesterday' })).code, 400);
  assert.equal((await post({ ...good, event: '' })).code, 400);
  assert.equal((await post({ ...good, fields: { tool: 'x', amount: 406600 } })).code, 400, 'unknown field key');
  assert.equal((await post({ ...good, fields: { note: 'a'.repeat(41) } })).code, 400);
  assert.equal((await post({ ...good, fields: ['tool'] })).code, 400);
});

test('telemetry: 204 on good body', async () => {
  assert.equal((await post(good)).code, 204);
  assert.equal((await post({ ...good, fields: { name: 'book', ok: false } })).code, 204);
  assert.equal((await post({ ...good, fields: {} })).code, 204);
});
