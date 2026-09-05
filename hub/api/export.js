import { store } from '../lib/store.js';
import { toMarkdown } from '../lib/export.js';
import { fail } from '../lib/http.js';

export default async function handler(req, res) {
  if (req.method !== 'GET') return fail(res, 405, 'method');
  const { app } = req.query ?? {};
  if (!app) return fail(res, 400, 'app');
  res.setHeader('content-type', 'text/markdown; charset=utf-8');
  return res.status(200).send(toMarkdown(app, await store.list(app)));
}
