import { store } from '../lib/store.js';
import { body, fail } from '../lib/http.js';

// ponytail: verifier identity is the unsigned `publisher` in the body; sign it if gaming shows up.
export default async function handler(req, res) {
  if (req.method !== 'POST') return fail(res, 405, 'method');
  const b = body(req);
  const short = v => typeof v === 'string' && v.length > 0 && v.length <= 64;
  if (!b || !short(b.id) || typeof b.ok !== 'boolean' || !short(b.publisher)) return fail(res, 400, 'body');
  const r = await store.get(b.id);
  if (!r) return fail(res, 404, 'id');
  if (!(await store.once(`ver:${b.id}:${b.publisher}`, 86400))) return res.status(200).json({ id: r.id, verified: r.verified, counted: false });
  const v = r.verified, now = new Date().toISOString();
  if (b.ok) { v.ok++; v.lastOk = now; } else { v.fail++; v.lastFail = now; }
  if (short(b.appVersion) && !v.versions.includes(b.appVersion)) v.versions = [...v.versions, b.appVersion].slice(-10);
  await store.put(r); // ponytail: read-modify-write, no lock; move counters to INCR keys if verifies collide
  return res.status(200).json({ id: r.id, verified: v, counted: true });
}
