import { promises as fs } from 'fs';
import { join } from 'path';
import { loadEdges, foldToCurrent, validAt, CurrentEdge, EdgeRecord, EdgeType } from './graph-store.js';
import { extractYamlList, extractYamlValue, matchFrontmatter, replaceFrontmatter } from './frontmatter.js';
import { walkWiki } from './walk-wiki.js';

export interface ProjectResult { pagesUpdated: number; }

const BEGIN = '<!-- graph:begin (generated from ~/knowledge/graph/edges.jsonl — do not hand-edit) -->';
const END = '<!-- graph:end -->';
const TYPE_LABEL: Record<EdgeType, string> = {
  requires: 'Requires', affects: 'Affects', part_of: 'Part of', supersedes: 'Supersedes', relates: 'Related',
};
const TYPE_ORDER: EdgeType[] = ['requires', 'affects', 'part_of', 'supersedes', 'relates'];

function slugFromPath(p: string): string { return p.replace(/^.*[\\/]/, '').replace(/\.md$/, ''); }
function escapeRe(s: string): string { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

/** Is this path inside a generated MOC dir (projects/, themes/)? Must accept BOTH
 *  separators: on Windows the walk yields backslash paths, and the previous
 *  /-only regex never matched — graph blocks were injected into generated MOCs. */
export function isGeneratedMocPath(p: string): boolean {
  return /[/\\](projects|themes)[/\\]/.test(p);
}

/** Regenerate related: frontmatter + the ## Dependencies block on every page,
 *  from current-valid edges. No edges.jsonl ⇒ no-op (returns pagesUpdated:0).
 *  `preloadedEdges` lets knowledgeReindex thread its single loadEdges result
 *  instead of re-parsing edges.jsonl. */
export async function projectGraphToPages(knowledgeDir: string, preloadedEdges?: EdgeRecord[]): Promise<ProjectResult> {
  const records = preloadedEdges ?? await loadEdges(join(knowledgeDir, 'graph', 'edges.jsonl'));
  if (records.length === 0) return { pagesUpdated: 0 };

  const now = new Date().toISOString();
  const wikiRoot = join(knowledgeDir, 'wiki');
  // includeIndex: index slugs must stay in livePages so edges to them survive the live-endpoint filter.
  const files = await walkWiki(wikiRoot, { includeIndex: true, skipHidden: true });

  // livePages = every on-disk page slug ∪ every `project:` facet value. The
  // union matters: a `part_of -> <project-key>` edge legitimately targets a
  // generated MOC slug that is materialized only AFTER this projection runs,
  // so without it that edge would be dropped on reindex-1 and re-added on
  // reindex-2 (breaks idempotency). Filtering `current` to live endpoints
  // stops the projector re-emitting dead `related:`/`## Dependencies` links to
  // a page that was deleted (the dangling-reference / noise bug).
  const livePages = new Set(files.map(slugFromPath));
  await Promise.all(files.map(async f => {
    try {
      const head = (await fs.readFile(f, 'utf-8')).slice(0, 4096);
      const fm = matchFrontmatter(head);
      const proj = fm ? extractYamlValue(fm.fm, 'project') : '';
      if (proj) livePages.add(proj);
    } catch { /* unreadable — its own slug is already in livePages */ }
  }));

  const current = foldToCurrent(records).filter(e => validAt(e, now))
    .filter(e => livePages.has(e.from) && livePages.has(e.to));

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

  let updated = 0;

  for (const file of files) {
    // Skip index.md and the generated MOC dirs (projects/, themes/) — they are pure
    // projections; injecting related:/## Dependencies into a MOC would mangle it and break
    // reindex idempotency.
    if (file.endsWith('index.md') || isGeneratedMocPath(file)) continue;
    const slug = slugFromPath(file);
    const related = relatedBySlug.get(slug);

    let content = await fs.readFile(file, 'utf-8');
    const before = content;

    // Orphan-GC: an edgeless page is normally skipped, BUT one that still
    // carries generated artifacts from a PRIOR projection (a non-empty graph
    // `related:` line or a `## Dependencies` block) must be admitted so its
    // stale frontmatter+block get scrubbed — otherwise a node that lost its
    // only edge keeps a dangling related: target forever. `related: []` and a
    // clean page carry no artifacts, so a hand-authored empty page is never
    // touched (preserves the "clean page never rewritten" contract).
    // P3: admit ANY non-empty `related:` shape (inline β, bracketless legacy, OR
    // a multi-line block-list) plus a prior graph block — so an edgeless page that
    // carries a stale block-list `related:\n  - x` is scrubbed too, not just the
    // inline form. `related: []` and a clean page carry no artifacts (untouched).
    const fmForArtifacts = matchFrontmatter(content);
    const hasNonEmptyRelated = fmForArtifacts
      ? extractYamlList(fmForArtifacts.fm, 'related').length > 0
      : false;
    const hasGeneratedArtifacts = hasNonEmptyRelated || content.includes(BEGIN);
    if ((!related || related.size === 0) && !hasGeneratedArtifacts) continue;

    // 1. rewrite related: frontmatter (sorted union) — scoped to the FIRST
    // frontmatter block only, so a body line that happens to start "related:"
    // is never rewritten. Canonical β form `related: [a, b]` is valid YAML
    // (the bracketless `[[a]], [[b]]` form a real parser rejects); the regex
    // consumes any legacy block-list continuation lines so their children are
    // not orphaned under no key. Edgeless-but-dirty pages collapse to `[]`.
    const relList = related ? [...related].sort() : [];
    const relLine = relList.length ? `related: [${relList.join(', ')}]` : 'related: []';
    const fmMatch = matchFrontmatter(content);
    if (fmMatch) {
      let fmBody = fmMatch.fm;
      const relBlockRe = /^related:[^\n]*(?:\n[ \t]+-[^\n]*)*$/m;
      if (relBlockRe.test(fmBody)) {
        fmBody = fmBody.replace(relBlockRe, () => relLine);
      } else if (relList.length) {
        fmBody = `${fmBody}\n${relLine}`;   // only ADD a line when there are edges
      }
      content = replaceFrontmatter(content, fmBody);
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
