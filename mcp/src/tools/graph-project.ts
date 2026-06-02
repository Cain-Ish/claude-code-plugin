import { promises as fs } from 'fs';
import { join } from 'path';
import { glob } from 'glob';
import { loadEdges, foldToCurrent, validAt, CurrentEdge, EdgeType } from './graph-store.js';

export interface ProjectResult { pagesUpdated: number; }

const BEGIN = '<!-- graph:begin (generated from ~/knowledge/graph/edges.jsonl — do not hand-edit) -->';
const END = '<!-- graph:end -->';
const TYPE_LABEL: Record<EdgeType, string> = {
  requires: 'Requires', affects: 'Affects', part_of: 'Part of', supersedes: 'Supersedes', relates: 'Related',
};
const TYPE_ORDER: EdgeType[] = ['requires', 'affects', 'part_of', 'supersedes', 'relates'];

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
    // Skip index.md and the generated MOC dirs (projects/, themes/) — they are pure
    // projections; injecting related:/## Dependencies into a MOC would mangle it and break
    // reindex idempotency.
    if (file.endsWith('index.md') || /\/(projects|themes)\//.test(file)) continue;
    const slug = slugFromPath(file);
    const related = relatedBySlug.get(slug);
    if (!related || related.size === 0) continue;

    let content = await fs.readFile(file, 'utf-8');
    const before = content;

    // 1. rewrite related: frontmatter (sorted union) — scoped to the FIRST
    // frontmatter block only, so a body line that happens to start "related:"
    // is never rewritten. Function replacers avoid `$`-pattern interpretation.
    const relList = [...related].sort();
    const relLine = `related: ${relList.map(s => `[[${s}]]`).join(', ')}`;
    const fmMatch = content.match(/^---\n([\s\S]*?)\n---/);
    if (fmMatch) {
      let fmBody = fmMatch[1];
      fmBody = /^related:.*$/m.test(fmBody)
        ? fmBody.replace(/^related:.*$/m, () => relLine)
        : `${fmBody}\n${relLine}`;
      content = content.replace(/^---\n[\s\S]*?\n---/, () => `---\n${fmBody}\n---`);
    }

    // 2. rewrite (or strip) the ## Dependencies block. Static heading — NO date,
    // so an unchanged graph never re-dates the block and forces a daily rewrite.
    // Built from the page's typed OUT edges; if there are none, any stale block
    // is removed rather than left as an empty dated husk.
    const outs = (outBySlug.get(slug) ?? []);
    const grouped: Partial<Record<EdgeType, string[]>> = {};
    for (const e of outs) (grouped[e.type] ??= []).push(e.to);
    const lines = [BEGIN, '## Dependencies'];
    for (const t of TYPE_ORDER) {
      const slugs = (grouped[t] ?? []).sort();
      if (slugs.length) lines.push(`**${TYPE_LABEL[t]}:** ${slugs.map(s => `[[${s}]]`).join(', ')}`);
    }
    const hasRows = lines.length > 2;
    const block = hasRows ? [...lines, END].join('\n') : '';
    const blockRe = new RegExp(`\\n*${escapeRe(BEGIN)}[\\s\\S]*?${escapeRe(END)}`);
    if (blockRe.test(content)) {
      content = block ? content.replace(blockRe, () => `\n\n${block}`) : content.replace(blockRe, () => '');
    } else if (block) {
      content = content.replace(/\s*$/, () => `\n\n${block}\n`);
    }

    if (content !== before) { await fs.writeFile(file, content, 'utf-8'); updated++; }
  }
  return { pagesUpdated: updated };
}
