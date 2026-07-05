/**
 * P3a Task A4 -- code-map generator CLI: scan -> extract -> buildGraph ->
 * serialize -> write BRAIN_DIR/projects/<slug>/codemap/{graph.json,map.md}.
 * Invoked out-of-band by the drainer (Phase 3) and manually for smoke tests.
 *
 * FAIL-SOFT BOUNDARY (plan Task A4): exit 0 ALWAYS. This runs on the hook
 * path -- a codemap failure must never fail the drain -- so errors are
 * REPORTED on stderr, never signaled via exit code. This is the plan's
 * documented exception to the fail-loud rule; the pure modules underneath
 * still throw.
 *
 * Flags:
 *   --check  print 'fresh' | 'stale' and do nothing else. PLACEHOLDER until
 *            Phase 3 wires drift.ts: fresh == graph.json exists with a
 *            git_rev matching HEAD (a dirty tree with an unchanged rev reads
 *            fresh -- known limit, fixed by Task C1).
 *   --force  regenerate unconditionally (the no-flag path skips when the
 *            placeholder check says fresh, mirroring the eventual C1 gate).
 *
 * Wall-clock (generated_at) and env reads live HERE at the CLI boundary --
 * everything below it is deterministic and pure.
 */

import { execFile } from 'child_process';
import { promisify } from 'util';
import { readFile } from 'fs/promises';
import { resolveBrainDir } from '../../brain-paths.js';
import { activeProjectDir, resolveActiveSlug } from '../project-dir.js';
import { scanSources } from './scan-sources.js';
import { extractFile } from './extract.js';
import { buildGraph } from './build-graph.js';
import { serialize } from './serialize.js';
import { codemapDir, readGraph, writeGraph } from './store.js';
import type { ExtractResult } from './types.js';

const execFileAsync = promisify(execFile);

/** HEAD sha + dirty bit; 'nogit' on any git failure (no repo, no git, no commits). */
async function gitState(repoRoot: string): Promise<{ rev: string; dirty: boolean }> {
  try {
    const { stdout: revOut } = await execFileAsync('git', ['rev-parse', 'HEAD'], {
      cwd: repoRoot,
      windowsHide: true,
    });
    const rev = revOut.trim();
    if (!rev) return { rev: 'nogit', dirty: false };
    const { stdout: statusOut } = await execFileAsync('git', ['status', '--porcelain'], {
      cwd: repoRoot,
      windowsHide: true,
      maxBuffer: 16 * 1024 * 1024,
    });
    return { rev, dirty: statusOut.trim().length > 0 };
  } catch {
    return { rev: 'nogit', dirty: false };
  }
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const force = argv.includes('--force');
  const check = argv.includes('--check');

  const repoRoot = activeProjectDir(); // CLAUDE_PROJECT_DIR || cwd (single-source helper)
  const brainDir = resolveBrainDir();
  const slug = resolveActiveSlug(brainDir);
  if (!slug) {
    process.stderr.write(
      `code-map: no active project slug resolvable for ${repoRoot} (degenerate basename?) -- skipped\n`,
    );
    return;
  }

  const dir = codemapDir(brainDir, slug);
  const { rev, dirty } = await gitState(repoRoot);
  // A corrupt/foreign-schema store reads as absent here: for --check that IS
  // stale, and for regen the rewrite is the repair -- the real error surfaces
  // on the write path if the disk itself is broken.
  const existing = await readGraph(dir).catch(() => null);
  const fresh = existing !== null && existing.git_rev === rev;

  if (check) {
    process.stdout.write(fresh ? 'fresh\n' : 'stale\n');
    return;
  }
  if (fresh && !force) {
    process.stderr.write(
      `code-map: ${slug} fresh at ${rev === 'nogit' ? 'nogit' : rev.slice(0, 7)} -- skipped (--force to regenerate)\n`,
    );
    return;
  }

  const scan = await scanSources(repoRoot);
  const idSet = new Set(scan.files.map((f) => f.id));
  // extractFile expands relative specifiers via candidateIds internally; the
  // injected resolver only answers membership over the scanned id set.
  const resolveId = (candidate: string): string | null =>
    idSet.has(candidate) ? candidate : null;

  const extracted = new Map<string, ExtractResult>();
  for (const f of scan.files) {
    let src: string;
    try {
      src = await readFile(f.abs, 'utf-8');
    } catch {
      // scanned-then-vanished (racing checkout/branch switch): an empty
      // extraction keeps the map whole instead of crashing mid-regen.
      src = '';
    }
    extracted.set(f.id, extractFile(f.id, src, f.lang, resolveId));
  }

  const graph = buildGraph(scan.files, extracted, {
    slug,
    repoRoot,
    gitRev: rev,
    dirty,
    generatedAt: new Date().toISOString(),
    truncated: scan.truncated,
  });
  const mapMd = serialize(graph);
  await writeGraph(dir, graph, mapMd);

  const shortRev = rev === 'nogit' ? 'nogit' : rev.slice(0, 7);
  process.stderr.write(
    `code-map: ${slug} files=${graph.files.length} edges=${graph.edges.length} rev=${shortRev}${dirty ? '+dirty' : ''}${graph.truncated ? ' truncated' : ''} map~${Math.ceil(mapMd.length / 4)}t -> ${dir}\n`,
  );
}

main().catch((e) => {
  process.stderr.write(`code-map: ERROR ${e instanceof Error ? e.message : String(e)}\n`);
  // no process.exit(1): fail-soft boundary, see header
});
