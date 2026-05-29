import { promises as fs } from 'fs';
import { join } from 'path';
import { glob } from 'glob';
import { loadEdges, foldToCurrent, validAt, CurrentEdge, EdgeType } from './graph-store.js';

export interface ProjectResult { pagesUpdated: number; }

const BEGIN = '<!-- graph:begin (generated from ~/knowledge/graph/edges.jsonl — do not hand-edit) -->';
const END = '<!-- graph:end -->';
const TYPE_LABEL: Partial<Record<EdgeType, string>> = {
  requires: 'Requires', affects: 'Affects', part_of: 'Part of', supersedes: 'Supersedes',
};

function slugFromPath(p: string): string { return p.replace(/.*\//, '').replace(/\.md$/, ''); }
function escapeRe(s: string): string { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

/** Regenerate related: frontmatter + the ## Dependencies block on every page,
 *  from current-valid edges. No edges.jsonl ⇒ no-op (returns pagesUpdated:0). */
export async function projectGraphToPages(knowledgeDir: string): Promise<ProjectResult> {
  const records = await loadEdges(join(knowledgeDir, 'graph', 'edges.jsonl'));
  if (records.length === 0) return { pagesUpdated: 0 };

  const now = new Date().toISOString();
  const current = foldToCurrent(records).filter(e => validAt(e, now));

  // Build per-slug direct neighbours (both directions) + typed out-edges.
  const outBySlug = new Map<string, CurrentEdge[]>();
  const relatedBySlug = new Map<string, Set<string>>();
  const add = (slug: string, other: string) => {
    if (!relatedBySlug.has(slug)) relatedBySlug.set(slug, new Set());
    relatedBySlug.get(slug)!.add(other);
  };
  for (const e of current) {
    if (!outBySlug.has(e.from)) outBySlug.set(e.from, []);
    outBySlug.get(e.from)!.push(e);   // typed deps shown on the source page
    add(e.from, e.to); add(e.to, e.from);
  }

  const wikiRoot = join(knowledgeDir, 'wiki');
  const files = await glob('**/*.md', { cwd: wikiRoot, absolute: true });
  let updated = 0;

  for (const file of files) {
    if (file.endsWith('index.md')) continue;
    const slug = slugFromPath(file);
    const related = relatedBySlug.get(slug);
    if (!related || related.size === 0) continue;

    let content = await fs.readFile(file, 'utf-8');
    const before = content;

    // 1. rewrite related: frontmatter (sorted union)
    const relList = [...related].sort();
    const relLine = `related: ${relList.map(s => `[[${s}]]`).join(', ')}`;
    if (/^related:.*$/m.test(content)) {
      content = content.replace(/^related:.*$/m, relLine);
    } else {
      // insert into frontmatter before the closing ---
      content = content.replace(/^---\n([\s\S]*?)\n---/, (_m, fm) => `---\n${fm}\n${relLine}\n---`);
    }

    // 2. rewrite the ## Dependencies block (grouped by type, source page's out-edges)
    const outs = (outBySlug.get(slug) ?? []);
    const grouped: Partial<Record<EdgeType, string[]>> = {};
    for (const e of outs) (grouped[e.type] ??= []).push(e.to);
    const lines = [BEGIN, `## Dependencies (as of ${now.slice(0, 10)})`];
    for (const t of ['requires', 'affects', 'part_of', 'supersedes'] as EdgeType[]) {
      const slugs = (grouped[t] ?? []).sort();
      if (slugs.length) lines.push(`**${TYPE_LABEL[t]}:** ${slugs.map(s => `[[${s}]]`).join(', ')}`);
    }
    lines.push(END);
    const block = lines.join('\n');
    const blockRe = new RegExp(`${escapeRe(BEGIN)}[\\s\\S]*?${escapeRe(END)}`);
    if (blockRe.test(content)) content = content.replace(blockRe, block);
    else content = content.replace(/\s*$/, `\n\n${block}\n`);

    if (content !== before) { await fs.writeFile(file, content, 'utf-8'); updated++; }
  }
  return { pagesUpdated: updated };
}
