/**
 * CLI: scan a wiki dir and print near-duplicate page pairs as JSON (MinHash/Jaccard, offline, no
 * embeddings). Invoked via the scripts/wiki-redundancy.sh shim by the dream DEDUPLICATE phase +
 * the FORGET redundancy gate. Mirrors graph-cluster-cli (same resolve/collect pattern, no deps).
 *
 * Usage: wiki-redundancy-cli <wiki-dir>
 *        wiki-redundancy-cli --knowledge-dir <kd>   (uses <kd>/wiki)
 * Env:   SB_REDUNDANCY_THRESHOLD (default 0.7), SB_REDUNDANCY_MAX_PAIRS (default 50)
 * Output: [{a,b,sim,a_cat,b_cat}, ...] sorted by sim desc — one JSON line.
 */
import { promises as fs } from 'fs';
import { join, basename, dirname } from 'path';
import { shingles, minhashSignature, nearDuplicatePairs, type PageSig } from './minhash.js';
import { resolveKnowledgeDir } from '../brain-paths.js';

function resolveWikiDir(argv: string[]): string {
  if (argv[0] === '--knowledge-dir' && argv[1]) return join(argv[1], 'wiki');
  if (argv[0]) return argv[0];
  return join(resolveKnowledgeDir(), 'wiki');
}

async function collect(dir: string, acc: string[] = []): Promise<string[]> {
  let entries;
  try { entries = await fs.readdir(dir, { withFileTypes: true }); } catch { return acc; }
  for (const e of entries) {
    const p = join(dir, e.name);
    // Skip generated MOC dirs (projects/, themes/): they are regenerable [[slug]] hubs, not authored
    // prose — and themes are FORGET-protected, so flagging them as duplicates is pure noise.
    if (e.isDirectory()) { if (!e.name.startsWith('.') && e.name !== 'projects' && e.name !== 'themes') await collect(p, acc); }
    else if (e.name.endsWith('.md') && e.name !== 'index.md') acc.push(p);
  }
  return acc;
}

function envFloat(name: string, def: number, lo: number, hi: number): number {
  const v = parseFloat(process.env[name] ?? '');
  return Number.isFinite(v) && v >= lo && v <= hi ? v : def;
}

async function main(): Promise<void> {
  const wikiDir = resolveWikiDir(process.argv.slice(2));
  const threshold = envFloat('SB_REDUNDANCY_THRESHOLD', 0.7, 0.01, 1);
  const mp = parseInt(process.env.SB_REDUNDANCY_MAX_PAIRS ?? '', 10);
  const maxPairs = Math.max(1, Number.isNaN(mp) ? 50 : mp); // NaN -> 50; never silently turn 0 into 50
  const files = await collect(wikiDir);
  const pages: PageSig[] = [];
  for (const f of files) {
    let content = '';
    try { content = await fs.readFile(f, 'utf-8'); } catch { continue; }
    if (!content.trim()) continue;
    const sh = shingles(content);
    if (sh.size === 0) continue; // prose-empty (frontmatter/ai-block-only stub) — not a dup candidate (C1)
    pages.push({ slug: basename(f, '.md'), cat: basename(dirname(f)), sig: minhashSignature(sh) });
  }
  const pairs = nearDuplicatePairs(pages, threshold).slice(0, maxPairs);
  process.stdout.write(JSON.stringify(pairs) + '\n');
}

main().catch((e) => { process.stderr.write(String(e) + '\n'); process.exit(1); });
