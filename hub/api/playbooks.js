import { defaultCatalogRoot, findPlaybook, readCatalog } from '../lib/catalog.js';
import { fail } from '../lib/http.js';

export function createCatalogHandler(catalogRoot = defaultCatalogRoot) {
  return async function handler(req, res) {
    if (req.method !== 'GET') {
      res.setHeader('Allow', 'GET');
      return fail(res, 405, 'method');
    }
    const { id } = req.query ?? {};
    if (id !== undefined && (typeof id !== 'string' || !id.trim())) return fail(res, 400, 'id');
    let catalog;
    try { catalog = await readCatalog(catalogRoot); }
    catch { return fail(res, 503, 'catalog unavailable'); }
    res.setHeader('Cache-Control', 'public, max-age=60, s-maxage=300');
    if (id !== undefined) {
      const record = findPlaybook(catalog, id);
      return record ? res.status(200).json(record) : fail(res, 404, 'playbook not found');
    }
    return res.status(200).json(catalog);
  };
}

export default createCatalogHandler();
