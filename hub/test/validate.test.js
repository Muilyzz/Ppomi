import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validate } from '../lib/validate.js';
import { record } from './fx.js';

const reasonsOf = over => validate(record(over)).reasons;

test('valid record passes', () => assert.deepEqual(validate(record()), { ok: true, reasons: [] }));

test('personal info is refused', () => {
  assert.ok(reasonsOf({ note: '총 406,600원 결제됨' }).includes('pii:amount'));
  assert.ok(reasonsOf({ note: '카드 1234-5678 사용' }).includes('pii:account'));
  assert.ok(reasonsOf({ note: '연락처 010-1234-5678' }).includes('pii:phone'));
  assert.ok(reasonsOf({ note: '문의 a@b.co' }).includes('pii:email'));
  assert.ok(reasonsOf({ note: 'https://x.y 참고' }).includes('pii:url'));
  assert.ok(reasonsOf({ note: '홍길동님 예약' }).includes('pii:name'));
  assert.ok(!reasonsOf({ note: '고객님 화면' }).includes('pii:name'));
});

test('payment word as tap target is refused', () => {
  const fp = ['최종', '금액', '결제하기'];
  assert.ok(reasonsOf({ target: '결제하기', fingerprintBefore: fp }).includes('target:payment'));
  assert.ok(reasonsOf({ glyph: '↓', target: '송금' }).includes('target:payment'), 'scroll-then-tap too');
  // regex that dodges the literal check but would still tap the payment button
  for (const target of ['하기', '.', '[결]제하기', '(결|x)제하기', '금액|결제하기'])
    assert.ok(reasonsOf({ target, fingerprintBefore: fp }).includes('target:payment'), target);
  assert.ok(!reasonsOf({ target: '금액', fingerprintBefore: fp }).includes('target:payment'), 'other word on a payment screen is fine');
  assert.ok(validate(record({ glyph: '🔍', target: '결제수단' })).ok, 'non-tap glyphs may name payment words');
});

test('tap target regex is bounded: no quantifiers, at most 8 alternatives', () => {
  for (const target of ['.?.?x', '객실*', '객실+', '객실{1,3}']) assert.ok(reasonsOf({ target }).includes('target:regex'), target);
  assert.ok(reasonsOf({ target: 'a|b|c|d|e|f|g|h|객실' }).includes('target:regex'));
  assert.ok(validate(record({ target: 'a|b|c|d|e|f|g|객실' })).ok);
  assert.ok(reasonsOf({ target: '' }).includes('target'));
});

test('unknown fields and pii in app/appVersion are refused', () => {
  assert.ok(reasonsOf({ extra: '홍길동님 010-1234-5678' }).includes('fields'));
  assert.ok(reasonsOf({ app: '홍길동님' }).includes('pii:name'));
  assert.ok(reasonsOf({ appVersion: 'a@b.co' }).includes('pii:email'));
});

test('unknown glyph, bad fingerprint, long note', () => {
  assert.ok(reasonsOf({ glyph: '★' }).includes('glyph'));
  assert.ok(reasonsOf({ fingerprintBefore: ['a', 'b'] }).includes('fingerprintBefore'));
  assert.ok(reasonsOf({ fingerprintAfter: ['x'.repeat(25), 'b', 'c'] }).includes('fingerprintAfter'));
  assert.ok(reasonsOf({ note: '가'.repeat(141) }).includes('note:length'));
});

test('tap target must appear in fingerprintBefore', () => {
  assert.ok(reasonsOf({ target: '예약하기' }).includes('target:not-in-fingerprint'));
  assert.ok(validate(record({ target: '없음|객실' })).ok);
  assert.ok(reasonsOf({ target: '(' }).includes('target:regex'));
});

test('tampered record fails signature', () => {
  const r = record();
  r.note = '바뀐 메모';
  assert.ok(validate(r).reasons.includes('sig'));
});
