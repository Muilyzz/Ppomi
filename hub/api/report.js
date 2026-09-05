import { store } from '../lib/store.js';
import { body, fail } from '../lib/http.js';

export default async function handler(req, res) {
  if (req.method !== 'POST') return fail(res, 405, 'method');
  const b = body(req);
  if (!b || typeof b.id !== 'string' || typeof b.reason !== 'string' || !b.reason || b.reason.length > 280) return fail(res, 400, 'body');
  const r = await store.get(b.id);
  if (!r) return fail(res, 404, 'id');
  const reports = await store.report(b.id);
  if (reports >= 1 && !r.quarantined) { r.quarantined = true; await store.put(r); }
  return res.status(200).json({ id: r.id, reports, quarantined: true });
}
