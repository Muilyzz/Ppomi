import { createPublicKey, generateKeyPairSync, sign, verify } from 'node:crypto';

const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex'); // ed25519 SubjectPublicKeyInfo header

const sortKeys = v =>
  Array.isArray(v) ? v.map(sortKeys)
  : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map(k => [k, sortKeys(v[k])]))
  : v;

/** Canonical JSON: keys sorted, undefined dropped. */
export const canonical = obj => JSON.stringify(sortKeys(obj));

/** The signed part of a record: everything the publisher owns (server fields stripped). */
export function payload(record) {
  const { sig, verified, tier, quarantined, ...owned } = record;
  return canonical(owned);
}

/** New ed25519 keypair. publisher = raw 32-byte public key, base64. */
export function keypair() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const publisher = publicKey.export({ type: 'spki', format: 'der' }).subarray(SPKI_PREFIX.length).toString('base64');
  return { publisher, privateKey };
}

export const signRecord = (record, privateKey) => sign(null, Buffer.from(payload(record)), privateKey).toString('base64');

export function verifyRecord(record) {
  try {
    const raw = Buffer.from(record.publisher, 'base64');
    if (raw.length !== 32) return false;
    const key = createPublicKey({ key: Buffer.concat([SPKI_PREFIX, raw]), format: 'der', type: 'spki' });
    return verify(null, Buffer.from(payload(record)), key, Buffer.from(record.sig, 'base64'));
  } catch {
    return false;
  }
}
