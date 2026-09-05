import { keypair, signRecord } from '../lib/sign.js';

export const keys = keypair();

/** A valid, signed community footprint; override any field before signing. */
export function record(over = {}, k = keys) {
  const r = {
    id: 'fp-' + Math.random().toString(36).slice(2, 10),
    app: '여기어때',
    glyph: '⊙',
    target: '모든 객실 보기',
    fingerprintBefore: ['숙소', '상세', '모든', '객실', '보기'],
    fingerprintAfter: ['객실', '목록', '예약하기', '더보기'],
    note: '객실 목록은 아래로만 스크롤된다.',
    publisher: k.publisher,
    createdAt: '2026-09-05T01:00:00.000Z',
    ...over,
  };
  r.sig = signRecord(r, k.privateKey);
  return r;
}

/** Call a Vercel-style handler with a fake req/res; resolves { code, body, headers }. */
export function call(handler, { method = 'GET', query = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const res = {
      code: 200, headers: {},
      status(c) { this.code = c; return this; },
      setHeader(k, v) { this.headers[k] = v; },
      json(b) { resolve({ code: this.code, body: b, headers: this.headers }); },
      send(b) { resolve({ code: this.code, body: b, headers: this.headers }); },
      end() { resolve({ code: this.code, body: undefined, headers: this.headers }); },
    };
    handler({ method, query, body }, res).catch(reject);
  });
}
