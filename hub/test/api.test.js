import { test } from 'node:test';
import assert from 'node:assert/strict';
import footprints from '../api/footprints.js';
import verify from '../api/verify.js';
import report from '../api/report.js';
import exportMd from '../api/export.js';
import { call, record, keys } from './fx.js';
import { keypair } from '../lib/sign.js';

const post = (h, body) => call(h, { method: 'POST', body });

test('publish → list → verify → report → quarantine', async () => {
  const r = record();
  assert.equal((await post(footprints, r)).code, 201);
  assert.equal((await post(footprints, r)).code, 409);
  assert.equal((await post(footprints, record({ note: '010-0000-0000' }))).code, 400);
  assert.equal((await post(footprints, { ...r, id: 'other', sig: 'AAAA' })).code, 400);

  let list = await call(footprints, { query: { app: '여기어때' } });
  assert.equal(list.code, 200);
  assert.deepEqual(list.body.footprints.map(f => f.id), [r.id]);
  assert.deepEqual(list.body.footprints[0].verified, { ok: 0, fail: 0, versions: [] });
  assert.equal(list.body.footprints[0].tier, 'community');
  assert.equal((await call(footprints, { query: { app: '여기어때', since: '2027-01-01' } })).body.footprints.length, 0);

  const v1 = await post(verify, { id: r.id, ok: true, appVersion: '5.2.0', publisher: keys.publisher });
  assert.equal(v1.body.counted, true);
  const v2 = await post(verify, { id: r.id, ok: true, publisher: keys.publisher });
  assert.equal(v2.body.counted, false, 'same publisher counts once a day');
  const v3 = await post(verify, { id: r.id, ok: false, publisher: 'someone-else' });
  assert.equal(v3.body.verified.ok, 1);
  assert.equal(v3.body.verified.fail, 1);
  assert.deepEqual(v3.body.verified.versions, ['5.2.0']);
  assert.ok(v3.body.verified.lastOk && v3.body.verified.lastFail);
  assert.equal((await post(verify, { id: 'nope', ok: true, publisher: 'x' })).code, 404);

  const rep = await post(report, { id: r.id, reason: '개인정보 포함' });
  assert.deepEqual(rep.body, { id: r.id, reports: 1, quarantined: true });
  list = await call(footprints, { query: { app: '여기어때' } });
  assert.equal(list.body.footprints.length, 0, 'quarantined footprints are hidden');
});

test('rate limit: 11th publish per minute is refused', async () => {
  const k = keypair(), codes = [];
  for (let i = 0; i < 11; i++) codes.push((await post(footprints, record({ app: 'rate' }, k))).code);
  assert.deepEqual(codes.slice(0, 10), Array(10).fill(201));
  assert.equal(codes[10], 429);
});

test('export renders playbook markdown with chained combo and habit lines', async () => {
  const app = '야놀자', k = keypair();
  const steps = [
    record({ app, glyph: '▶', target: '야놀자', fingerprintBefore: ['홈', '화면', '앱'], fingerprintAfter: ['홈', '검색', '최근', '본', '상품'], note: undefined }, k),
    record({ app, glyph: '⊙', target: '최근 본 상품|검색', fingerprintBefore: ['홈', '검색', '최근', '본', '상품'], fingerprintAfter: ['숙소', '상세', '날짜', '인원', '객실'], note: '홈에 최근 본 상품이 있으면 검색을 건너뛴다.' }, k),
    record({ app, glyph: '↓', target: '필수', fingerprintBefore: ['예약', '필수', '약관', '동의'], fingerprintAfter: ['결제', '수단', '쿠폰'], note: undefined }, k),
    record({ app, glyph: '⊙', target: '객실', fingerprintBefore: ['숙소', '상세', '날짜', '인원', '객실'], fingerprintAfter: ['예약', '필수', '약관', '동의'], note: '객실 목록은 아래로만 스크롤된다.' }, k),
    record({ app, glyph: '✋', target: '승인', fingerprintBefore: ['결제', '수단', '쿠폰'], fingerprintAfter: ['완료', '예약번호', '취소'], note: undefined }, k),
  ];
  for (const s of steps) assert.equal((await post(footprints, s)).code, 201);
  const out = await call(exportMd, { query: { app } });
  assert.equal(out.code, 200);
  assert.match(out.headers['content-type'], /markdown/);
  const lines = out.body.split('\n');
  assert.equal(lines[0], '# 야놀자');
  assert.equal(lines[1], '콤보: ▶야놀자 › ⊙최근 본 상품|검색 › ⊙객실 › ↓⊙필수 › ✋승인');
  assert.deepEqual(lines.slice(2, 4).sort(), ['- 2026-09-05 객실 목록은 아래로만 스크롤된다.', '- 2026-09-05 홈에 최근 본 상품이 있으면 검색을 건너뛴다.']);
  assert.equal(out.body.at(-1), '\n');
});
