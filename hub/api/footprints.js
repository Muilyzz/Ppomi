import { validate } from '../lib/validate.js';
import { store } from '../lib/store.js';
import { body, fail } from '../lib/http.js';

const VERIFIED = new Set((process.env.VERIFIED_PUBLISHERS ?? '').split(',').filter(Boolean));

export default async function handler(req, res) {
  if (req.method === 'POST') {
    const r = body(req);
    if (!r) return fail(res, 400, 'body');
    const { ok, reasons } = validate(r);
    if (!ok) return fail(res, 400, ...reasons);
    if (await store.get(r.id)) return fail(res, 409, 'exists');
    if ((await store.rate(r.publisher)) > 10) return fail(res, 429, 'rate');
    const { verified, tier, quarantined, ...owned } = r;
    await store.put({ ...owned, verified: { ok: 0, fail: 0, versions: [] }, tier: VERIFIED.has(r.publisher) ? 'verified' : 'community' });
    return res.status(201).json({ id: r.id });
  }
  if (req.method === 'GET') {
    const { app, since, tier } = req.query ?? {};
    if (!app) return fail(res, 400, 'app');
    let rows = await store.list(app);
    if (since) rows = rows.filter(r => Date.parse(r.createdAt) >= Date.parse(since));
    if (tier) rows = rows.filter(r => r.tier === tier);
    return res.status(200).json({ footprints: rows.slice(0, 200) });
  }
  return fail(res, 405, 'method');
}
