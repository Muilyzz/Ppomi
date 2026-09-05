export function body(req) {
  try { return (typeof req.body === 'string' ? JSON.parse(req.body) : req.body) ?? {}; } catch { return null; }
}
export const fail = (res, code, ...reasons) => res.status(code).json({ reasons });
