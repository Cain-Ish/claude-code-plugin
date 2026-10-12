import { promises as fs } from 'fs';
import { join } from 'path';
import { assertSafeSlug } from '../path-guard.js';
import type { DocEntry } from './doc-sources.js';

// Split out of doc-sources.ts (audit N3): the registry reader must not pull in `glob` (scanLocations'
// dependency) for callers that only load a registry.
export interface DocRegistry { generated_at: string; project: string; entries: DocEntry[]; }

export function registryPath(brainDir: string, slug: string): string {
  return join(brainDir, 'projects', slug, 'doc-sources.json');
}

export async function loadRegistry(brainDir: string, slug: string): Promise<DocRegistry | null> {
  try { assertSafeSlug(slug); return JSON.parse(await fs.readFile(registryPath(brainDir, slug), 'utf-8')); }
  catch { return null; }
}
