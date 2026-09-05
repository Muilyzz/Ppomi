import { store } from '../lib/store.js';
import { body, fail } from '../lib/http.js';

// Mirrors Telemetry.keys in Ppomi/Sources/Ppomi/Serve/Telemetry.swift — names and numbers only, never content.
const KEYS = new Set(['name', 'tool', 'ok', 'ms', 'app', 'step', 'reason']);
const plain = v => (typeof v === 'string' && v.length <= 40 && !v.includes('\n')) || typeof v === 'boolean' || Number.isFinite(v);

export default async function handler(req, res) {
  if (req.method !== 'POST') return fail(res, 405, 'method');
  const b = body(req);
  if (!b || typeof b.ts !== 'string' || !Number.isFinite(Date.parse(b.ts))) return fail(res, 400, 'ts');
  if (typeof b.event !== 'string' || !b.event || b.event.length > 64 || /[:\n]/.test(b.event)) return fail(res, 400, 'event');
  const f = b.fields;
  if (!f || typeof f !== 'object' || Array.isArray(f) || !Object.entries(f).every(([k, v]) => KEYS.has(k) && plain(v))) return fail(res, 400, 'fields');
  await store.tally(`tm:${b.event}:${f.name ?? f.tool ?? ''}:${f.ok === false ? 'fail' : 'ok'}`);
  return res.status(204).end();
}
