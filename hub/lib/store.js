// KV abstraction. @vercel/kv when KV_REST_API_URL is set, else an in-memory Map (tests/local).
function memory() {
  const m = new Map(); // key -> { v, exp }
  const live = k => {
    const e = m.get(k);
    if (e && e.exp && e.exp < Date.now()) { m.delete(k); return undefined; }
    return e;
  };
  return {
    async get(k) { return live(k)?.v ?? null; },
    async mget(...ks) { return ks.map(k => live(k)?.v ?? null); },
    async set(k, v, o = {}) {
      if (o.nx && live(k)) return null;
      m.set(k, { v: structuredClone(v), exp: o.ex ? Date.now() + o.ex * 1000 : 0 });
      return 'OK';
    },
    async incr(k) { const e = live(k); const n = (e?.v ?? 0) + 1; m.set(k, { v: n, exp: e?.exp ?? 0 }); return n; },
    async expire(k, s) { const e = live(k); if (e) e.exp = Date.now() + s * 1000; },
    async sadd(k, v) { const e = live(k) ?? { v: new Set(), exp: 0 }; e.v.add(v); m.set(k, e); },
    async smembers(k) { return [...(live(k)?.v ?? [])]; },
  };
}

if (process.env.VERCEL && !process.env.KV_REST_API_URL) throw new Error('KV_REST_API_URL missing: refusing to run on an in-memory store');
const kv = process.env.KV_REST_API_URL ? (await import('@vercel/kv')).kv : memory();

const fpKey = (app, id) => `fp:${app}:${id}`;
const byRank = (a, b) => (b.tier === 'verified') - (a.tier === 'verified') || b.verified.ok - a.verified.ok;

export const store = {
  /** Insert or overwrite a footprint (also indexes it). */
  async put(r) {
    await Promise.all([kv.set(fpKey(r.app, r.id), r), kv.set(`app:${r.id}`, r.app), kv.sadd(`idx:${r.app}`, r.id)]);
  },
  async get(id) {
    const app = await kv.get(`app:${id}`);
    return app ? kv.get(fpKey(app, id)) : null;
  },
  /** Non-quarantined footprints of an app: verified tier first, then verified.ok desc. */
  async list(app) {
    const ids = await kv.smembers(`idx:${app}`);
    const rows = ids.length ? await kv.mget(...ids.map(id => fpKey(app, id))) : [];
    return rows.filter(r => r && !r.quarantined).sort(byRank);
  },
  /** Per-minute publish count for a publisher (TTL 60s). */
  async rate(publisher) {
    const k = `pub:${publisher}:rate`;
    const n = await kv.incr(k);
    if (n === 1) await kv.expire(k, 60);
    return n;
  },
  async report(id) { return kv.incr(`rep:${id}`); },
  /** Increment a plain counter key (telemetry tallies). */
  async tally(key) { return kv.incr(key); },
  /** True the first time `key` is claimed within `sec` seconds. */
  async once(key, sec) { return (await kv.set(key, 1, { nx: true, ex: sec })) !== null; },
};
