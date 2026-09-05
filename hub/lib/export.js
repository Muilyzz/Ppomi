// ponytail: combo order is inferred by chaining fingerprintAfter → fingerprintBefore word overlap.
// Add an explicit step index to the record if chains turn out ambiguous.
export function chain(records) {
  const left = new Set(records);
  let cur = records.find(r => r.glyph === '▶') ?? records[0];
  const out = [];
  while (cur) {
    out.push(cur);
    left.delete(cur);
    const after = new Set(cur.fingerprintAfter);
    let best = null, score = 0;
    for (const r of left) {
      const s = r.fingerprintBefore.filter(w => after.has(w)).length;
      if (s > score) { best = r; score = s; }
    }
    cur = best;
  }
  return out;
}

const step = r => (r.glyph === '↓' ? '↓⊙' : r.glyph) + r.target;

/** Playbook markdown in the data/playbooks/<app>.md shape. */
export function toMarkdown(app, records) {
  const combo = chain(records).map(step).join(' › ');
  const habits = [...new Set(records.filter(r => r.note).map(r => `- ${r.createdAt.slice(0, 10)} ${r.note}`))];
  return [`# ${app}`, `콤보: ${combo}`, ...habits].join('\n') + '\n';
}
