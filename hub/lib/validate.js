import { verifyRecord } from './sign.js';

export const GLYPHS = '▶⊙⌨↓⎋👤🎟🔍✋📝';
const TAP = '⊙↓';
const PAYWORDS = ['결제', '송금', '이체', '구매', '주문', '입금', '충전'];
const PAYMENT = new RegExp(PAYWORDS.join('|'));
const KEYS = new Set(['id', 'app', 'appVersion', 'glyph', 'target', 'fingerprintBefore', 'fingerprintAfter', 'note', 'publisher', 'sig', 'createdAt', 'verified', 'tier', 'quarantined']);
const PII = [
  ['pii:amount', /\d{1,3}(,\d{3})+원|₩/],
  ['pii:account', /\d{4}-\d{4}/],
  ['pii:phone', /0\d{1,2}-?\d{3,4}-?\d{4}/],
  ['pii:email', /[\w.+-]+@[\w-]+\.\w+/],
  ['pii:url', /https?:\/\/|www\./i],
];
// ponytail: honorific heuristic — "고객님"류는 UI 단어라 통과, 나머지 2~4자+님은 이름으로 본다
const COMMON_NIM = /(고객|회원|손|선생|사장|사용자|여러분|어르신)님$/;
const hasName = text => (text.match(/[가-힣]{2,4}님/g) ?? []).some(n => !COMMON_NIM.test(n));

const isStr = (v, max) => typeof v === 'string' && v.length <= max;
const isFingerprint = a =>
  Array.isArray(a) && a.length >= 3 && a.length <= 8 && a.every(w => isStr(w, 24) && w.length > 0);

/** Pure check of one footprint record. */
export function validate(r) {
  const reasons = [];
  if (!r || typeof r !== 'object') return { ok: false, reasons: ['record'] };
  if (Object.keys(r).some(k => !KEYS.has(k))) reasons.push('fields');
  if (!isStr(r.id, 64) || !/^[\w-]+$/.test(r.id)) reasons.push('id');
  if (!isStr(r.app, 32) || !r.app || /[:/\s]/.test(r.app)) reasons.push('app');
  if (r.appVersion !== undefined && !isStr(r.appVersion, 32)) reasons.push('appVersion');
  if (!isStr(r.glyph, 2) || ![...GLYPHS].includes(r.glyph)) reasons.push('glyph');
  if (!isStr(r.target, 80) || (TAP.includes(r.glyph) && !r.target)) reasons.push('target');
  if (!isFingerprint(r.fingerprintBefore)) reasons.push('fingerprintBefore');
  if (!isFingerprint(r.fingerprintAfter)) reasons.push('fingerprintAfter');
  if (r.note !== undefined && !isStr(r.note, 140)) reasons.push('note:length');
  if (!isStr(r.createdAt, 40) || !Number.isFinite(Date.parse(r.createdAt))) reasons.push('createdAt');
  if (reasons.length) return { ok: false, reasons };

  const text = [r.app, r.appVersion ?? '', r.target, r.note ?? '', ...r.fingerprintBefore, ...r.fingerprintAfter].join(' ');
  for (const [reason, re] of PII) if (re.test(text)) reasons.push(reason);
  if (hasName(text)) reasons.push('pii:name');

  if (TAP.includes(r.glyph)) {
    // ponytail: no quantifiers and ≤8 alternatives → backtracking ≤2^7 paths, so a hostile target can't stall the function.
    // A target is the words to tap, not a program; loosen only with a linear-time engine (V8 `l` flag).
    let re;
    if (/[*+?{]/.test(r.target) || r.target.split('|').length > 8) reasons.push('target:regex');
    else try { re = new RegExp(r.target, 'u'); } catch { reasons.push('target:regex'); }
    // what gets tapped is whatever screen word the regex matches — so test it against payment words and
    // against the publisher's own screen words that contain one (catches `.`, `[결]제`, `하기`→"결제하기")
    if (PAYMENT.test(r.target) || (re && [...PAYWORDS, ...r.fingerprintBefore].some(w => PAYMENT.test(w) && re.test(w)))) reasons.push('target:payment');
    if (re && r.glyph === '⊙' && !re.test(r.fingerprintBefore.join(' '))) reasons.push('target:not-in-fingerprint');
  }
  if (!verifyRecord(r)) reasons.push('sig');
  return { ok: reasons.length === 0, reasons };
}
