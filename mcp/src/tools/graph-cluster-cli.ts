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
import { resolveKnowledgeDir } from '../brain-paths.js';
import { matchFrontmatter, stripFrontmatter } from './frontmatter.js';
import { walkWiki } from './walk-wiki.js';

function resolveWikiDir(argv: string[]): string {
  if (argv[0] === '--knowledge-dir' && argv[1]) return join(argv[1], 'wiki');
  if (argv[0]) return argv[0];
  const kd = resolveKnowledgeDir();
  return join(kd, 'wiki');
}

function frontmatter(content: string): string {
  return matchFrontmatter(content)?.fm ?? '';
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
  // Skip generated MOC dirs (projects/, themes/): they are pure [[slug]] hubs over their
  // members, so clustering them would re-introduce exactly the hubs the MOC layer removes.
  const files = await walkWiki(wikiDir, { skipHidden: true, skipDirs: ['projects', 'themes'] });
  const pages: ClusterPage[] = [];
  const contentHash: Record<string, string> = {};
  for (const f of files) {
    let content = '';
    try { content = await fs.readFile(f, 'utf-8'); } catch { continue; }
    if (!content.trim()) continue;
    const slug = basename(f, '.md');   // separator-agnostic (repo convention; cross-platform)
    const fm = frontmatter(content);
    // Skip generated pages (reflection-*, theme copies outside themes/, state pages) from
    // clustering INPUT, for the same reason the projects/themes dirs are skipped: they are
    // synthesized hubs over their members. A reflection page lives in learnings/ or concepts/
    // with `related:` listing every cluster member, so clustering it makes it a member of its
    // OWN cluster — member_hash never matches again (idempotence defeated, the LLM re-reflects
    // every dream) and when `reflection-<id>` sorts lexicographically first it BECOMES the
    // cluster id, spawning reflection-reflection-<id>/theme-reflection-<id> pages each run.
    if (/^generated:[ \t]*true\b/m.test(fm)) continue;
    const body = stripFrontmatter(content);
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
