/**
 * CLI: cluster a wiki's link graph and print theme-cluster candidates as JSON.
 * Reads each page's `related:` frontmatter + body [[links]] (no live edges.jsonl —
 * staging-local), runs deterministic label propagation, and emits clusters >= minSize
 * with a content-aware member_hash. No external deps (offline, fast). Invoked via the
 * scripts/graph-cluster.sh shim from the dream-runner. Spec: 2026-06-01-dream-consolidation-v2.
 *
 * Usage: graph-cluster-cli <wiki-dir>
 *        graph-cluster-cli --knowledge-dir <kd>   (uses <kd>/wiki)
 * Env:   SB_SUMMARIZE_MIN_CLUSTER (default 4)
 */
import { promises as fs } from 'fs';
import { join, basename } from 'path';
import { buildAdjacency, labelPropagate, clusters, memberHash, djb2, type ClusterPage } from './graph-cluster.js';

function resolveWikiDir(argv: string[]): string {
  if (argv[0] === '--knowledge-dir' && argv[1]) return join(argv[1], 'wiki');
  if (argv[0]) return argv[0];
  const kd = process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR || process.env.KNOWLEDGE_DIR || join(process.env.HOME ?? '', 'knowledge');
  return join(kd, 'wiki');
}

async function collect(dir: string, acc: string[] = []): Promise<string[]> {
  let entries;
  try { entries = await fs.readdir(dir, { withFileTypes: true }); } catch { return acc; }
  for (const e of entries) {
    const p = join(dir, e.name);
    // Skip generated MOC dirs (projects/, themes/): they are pure [[slug]] hubs over their
    // members, so clustering them would re-introduce exactly the hubs the MOC layer removes.
    if (e.isDirectory()) { if (!e.name.startsWith('.') && e.name !== 'projects' && e.name !== 'themes') await collect(p, acc); }
    else if (e.name.endsWith('.md') && e.name !== 'index.md') acc.push(p);
  }
  return acc;
}

function frontmatter(content: string): string {
  const m = content.match(/^---\n([\s\S]*?)\n---/);
  return m ? m[1] : '';
}
function links(text: string): string[] {
  return [...text.matchAll(/\[\[([^\]]+)\]\]/g)].map(m => m[1].split('|')[0].trim()).filter(Boolean);
}
function relatedFrom(fm: string): string[] {
  const line = fm.split('\n').find(l => /^related:/.test(l));
  if (!line) return [];
  const wl = links(line);                       // wiki convention: related: [[a]], [[b]]
  if (wl.length) return wl;
  // plain YAML inline list (e.g. knowledge-validate addFrontmatter): related: [a, b] / []
  const m = line.match(/^related:\s*\[(.*)\]\s*$/);
  if (!m) return [];
  return m[1].split(',')
    .map(s => s.trim().replace(/^["']|["']$/g, ''))
    .filter(s => /^[a-z0-9][a-z0-9-]*$/i.test(s));
}

async function main(): Promise<void> {
  const wikiDir = resolveWikiDir(process.argv.slice(2));
  const minSize = parseInt(process.env.SB_SUMMARIZE_MIN_CLUSTER ?? '4', 10) || 4;
  const files = await collect(wikiDir);
  const pages: ClusterPage[] = [];
  const contentHash: Record<string, string> = {};
  for (const f of files) {
    let content = '';
    try { content = await fs.readFile(f, 'utf-8'); } catch { continue; }
    if (!content.trim()) continue;
    const slug = basename(f, '.md');   // separator-agnostic (repo convention; cross-platform)
    const fm = frontmatter(content);
    const body = content.replace(/^---\n[\s\S]*?\n---/, '');
    pages.push({ slug, related: relatedFrom(fm), bodyLinks: [...new Set(links(body))] });
    contentHash[slug] = djb2(content);
  }
  const maxPages = parseInt(process.env.SB_SUMMARIZE_MAX_PAGES ?? '8', 10) || 8;
  const labels = labelPropagate(buildAdjacency(pages));
  // Enforce the cap deterministically in code (the agent prose states it too, but bound the
  // output regardless): keep the LARGEST clusters (most thematic), tie-break by id, then
  // restore id order for stable output.
  const capped = [...clusters(labels, { minSize })]
    .sort((a, b) => b.members.length - a.members.length || (a.id < b.id ? -1 : 1))
    .slice(0, maxPages)
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const out = capped.map(c => ({
    id: c.id, members: c.members, member_hash: memberHash(c.members, contentHash),
  }));
  process.stdout.write(JSON.stringify(out) + '\n');
}

main().catch(e => { process.stderr.write(String(e) + '\n'); process.exit(1); });
