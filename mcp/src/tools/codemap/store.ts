/**
 * P3a Task A4 -- per-project codemap store: BRAIN_DIR/projects/<slug>/codemap/
 * holding graph.json (machine tier) + map.md (token-capped injection tier).
 *
 * Deliberately separate from the wiki graph (KNOWLEDGE_DIR/graph) -- see the
 * plan's "Separation from the wiki graph" table. Callers resolve brainDir via
 * resolveBrainDir() and slug via resolveActiveSlug(); this module only shapes
 * paths and moves bytes, so tests can point it at a temp dir directly.
 *
 * Writes are tmp+rename atomic, but unlike tools/atomic-write.ts (hook path,
 * swallows failures) a failed write THROWS: the only caller is the CLI, whose
 * fail-soft boundary reports the error to stderr -- swallowing here would
 * hide a dead store behind a green exit.
 */

import { promises as fs } from 'fs';
import * as path from 'path';
import type { CodeGraph } from './types.js';

export function codemapDir(brainDir: string, slug: string): string {
  return path.join(brainDir, 'projects', slug, 'codemap');
}

async function atomicWrite(filePath: string, data: string): Promise<void> {
  // pid suffix: concurrent regens (drainer tick + manual CLI) must not tear
  // each other's temp file; rename makes the last completed writer win whole.
  const tmp = `${filePath}.tmp.${process.pid}`;
  try {
    await fs.writeFile(tmp, data, 'utf-8');
    await fs.rename(tmp, filePath);
  } catch (e) {
    try {
      await fs.unlink(tmp);
    } catch {
      /* tmp never materialized */
    }
    throw e;
  }
}

export async function writeGraph(dir: string, graph: CodeGraph, mapMd: string): Promise<void> {
  await fs.mkdir(dir, { recursive: true });
  await atomicWrite(path.join(dir, 'graph.json'), JSON.stringify(graph) + '\n');
  await atomicWrite(path.join(dir, 'map.md'), mapMd);
}

/** null = no store yet (first run, a normal state); corrupt/foreign schema THROWS. */
export async function readGraph(dir: string): Promise<CodeGraph | null> {
  const file = path.join(dir, 'graph.json');
  let raw: string;
  try {
    raw = await fs.readFile(file, 'utf-8');
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === 'ENOENT') return null;
    throw e;
  }
  const parsed = JSON.parse(raw) as CodeGraph; // parse error propagates -- fail loud
  if (parsed === null || typeof parsed !== 'object' || parsed.schema !== 1) {
    throw new Error(`readGraph: unrecognized graph schema in ${file}`);
  }
  return parsed;
}
