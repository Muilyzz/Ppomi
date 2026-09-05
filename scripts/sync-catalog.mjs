#!/usr/bin/env node
import { mkdir, mkdtemp, writeFile, rm, rename } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { readCatalog, readPackageFile } from '../hub/lib/catalog.js';

const repositoryRoot = fileURLToPath(new URL('../', import.meta.url));
export const sourceCatalog = path.join(repositoryRoot, 'Ppomi/Sources/Ppomi/Catalog');
export const stagedCatalog = path.join(repositoryRoot, 'hub/catalog');

/** Generate deployable data only, preserving canonical bytes and excluding runtime evidence. */
export async function syncCatalog(source = sourceCatalog, target = stagedCatalog) {
  source = path.resolve(source);
  target = path.resolve(target);
  if (source === target || source.startsWith(target + path.sep) || target.startsWith(source + path.sep)) {
    throw new Error('Catalog source and target must be separate directories');
  }
  const catalog = await readCatalog(source); // Fail before replacing a previously valid deployment copy.
  await mkdir(path.dirname(target), { recursive: true });
  const temporary = await mkdtemp(path.join(path.dirname(target), '.catalog-staging-'));
  try {
    await writeFile(path.join(temporary, 'common.md'), await readPackageFile(source, 'common.md'));
    for (const { manifest } of catalog.playbooks) {
      const packageSource = path.join(source, manifest.id);
      const packageTarget = path.join(temporary, manifest.id);
      for (const asset of new Set(['manifest.json', manifest.guide, ...(manifest.icon ? [manifest.icon] : [])])) {
        const destination = path.join(packageTarget, asset);
        await mkdir(path.dirname(destination), { recursive: true });
        await writeFile(destination, await readPackageFile(packageSource, asset));
      }
    }
    await readCatalog(temporary);
    await rm(target, { recursive: true, force: true });
    await rename(temporary, target);
    return catalog.playbooks.length;
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const count = await syncCatalog();
    process.stdout.write(`Staged ${count} playbook packages from the canonical catalog.\n`);
  } catch (error) {
    process.stderr.write(`Catalog staging failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
