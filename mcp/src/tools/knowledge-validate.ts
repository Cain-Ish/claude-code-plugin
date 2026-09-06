import { promises as fs } from 'fs';
import { join, basename, dirname, relative } from 'path';
import yaml from 'js-yaml';
import { parseDoc, ParsedDoc, extractYamlList, matchFrontmatter, replaceFrontmatter, stripFrontmatter, hasFrontmatterFence } from './frontmatter.js';
import { parseAiBlock, validateAiBlock, stripAiBlock, schemaFor } from './ai-block.js';
import { ALL_CATEGORIES, FRONTMATTER_REQUIRED } from '../constants/kb-schema.js';
import { loadEdges, foldToCurrent, validAt, EdgeRecord } from './graph-store.js';
import { walkWiki } from './walk-wiki.js';

// The canonical required frontmatter field set — the same 7 fields addFrontmatter
// emits; sourced from kb-schema.json so every machine and the bash side agree.
// A node is in "best shape" when all are present (node-shape convergence).
const REQUIRED_FM_FIELDS = FRONTMATTER_REQUIRED;

// A structured page with this much prose (non-frontmatter, marked regions stripped) but no
// ai-block is a backfill candidate; shorter pages are legitimate stubs, exempt. Env-overridable
// in lockstep with kb-ai-block-candidates.sh / lint Check 4 (default 200).
const AI_BLOCK_MIN_PROSE = Number(process.env.SB_AI_BLOCK_MIN_PROSE) || 200;

// D066: empty_page issues are recorded during the initial full-tree scan, but autofix unlinks
// them only after that whole scan finishes — a real elapsed window on a large wiki. Pages are
// created non-atomically here (merge-project-update.sh's `> target_file` truncate-then-write,
// Obsidian's/Claude's Write tool 0-byte-then-content sequence), and concurrent sessions mutating
// the shared tree are a documented reality on this machine. A page younger than this is treated
// as possibly mid-write and left alone even if it re-reads empty.
const EMPTY_PAGE_MIN_AGE_MS = 2000;

export interface ValidationIssue {
  type: 'orphan_file' | 'broken_link' | 'missing_frontmatter' | 'malformed_frontmatter' | 'incomplete_frontmatter' | 'related_drift' | 'duplicate_slug' | 'stale_page' | 'empty_page' | 'root_orphan' | 'ai_block_incomplete' | 'ai_block_missing';
  severity: 'error' | 'warning';
  path: string;
  message: string;
  autofix?: string;
}

export interface ValidationResult {
  issues: ValidationIssue[];
  fixed: number;
  pagesScanned: number;
}

export async function knowledgeValidate(
  knowledgeDir: string,
  opts: { autofix?: boolean; edges?: EdgeRecord[] } = {}
): Promise<ValidationResult> {
  const wikiDir = join(knowledgeDir, 'wiki');
  const issues: ValidationIssue[] = [];
  let fixed = 0;

  // Single edges.jsonl read per validate: the graphEnabled gate AND the drift
  // check below share it, and knowledgeReindex threads its own already-loaded
  // records via opts.edges (was three parses of the same file per reindex).
  const edgeRecords = opts.edges ?? await loadEdges(join(knowledgeDir, 'graph', 'edges.jsonl'));

  // P2: when the graph is enabled the PROJECTOR is the sole writer of related:
  // (it scrubs edgeless pages to `related: []`). patchFrontmatter must then NOT
  // body-derive a related: value the projector will overwrite — that oscillation
  // broke reindex idempotency. graphEnabled gates patchFrontmatter to emit `[]`.
  const graphEnabled = edgeRecords.length > 0;

  const allPages = await walkWiki(wikiDir);
  const slugMap = new Map<string, string[]>();
  const parsedDocs: ParsedDoc[] = [];

  for (const filePath of allPages) {
    const content = await fs.readFile(filePath, 'utf-8');
    const slug = basename(filePath, '.md');
    const doc = parseDoc(content, filePath);
    parsedDocs.push(doc);

    // AI-block checks (gentle, additive — spec §7). Block present but missing a required field
    // → ai_block_incomplete. A structured, SUBSTANTIVE page with NO block at all →
    // ai_block_missing (predates the feature / never authored). Stubs + non-structured types +
    // generated MOCs (projects/, themes/) are exempt.
    const aiBlock = parseAiBlock(content);
    const ptype = doc.type || basename(dirname(filePath));
    if (aiBlock) {
      const missing = validateAiBlock(ptype, aiBlock);
      if (missing.length) issues.push({
        type: 'ai_block_incomplete', severity: 'warning', path: filePath,
        message: `ai-block missing required field(s) for type ${ptype}: ${missing.join(', ')}`,
      });
    } else if (schemaFor(ptype) && !/[/\\](projects|themes)[/\\]/.test(filePath)) {
      const prose = stripFrontmatter(stripAiBlock(content)
        .replace(/<!--\s*graph:begin[\s\S]*?graph:end\s*-->/g, '')
        .replace(/<!--\s*theme:begin[\s\S]*?theme:end\s*-->/g, ''));
      if (prose.trim().length >= AI_BLOCK_MIN_PROSE) issues.push({
        type: 'ai_block_missing', severity: 'warning', path: filePath,
        message: `${ptype} page has substantive prose but no ai-block: ${slug}`,
      });
    }

    // Generated MOC dirs (projects/, themes/) are derived VIEWS, not source pages — a MOC that
    // shares a slug with a real page (e.g. project "architecture-v1" + page architecture-v1.md)
    // is not a true duplicate, so exclude them from the duplicate_slug check.
    if (!/[/\\](projects|themes)[/\\]/.test(filePath)) {
      if (!slugMap.has(slug)) slugMap.set(slug, []);
      slugMap.get(slug)!.push(filePath);
    }

    if (!content.trim()) {
      issues.push({
        type: 'empty_page',
        severity: 'error',
        path: filePath,
        message: `Empty page: ${slug}`,
        autofix: 'remove',
      });
    }

    // CRLF-tolerant (0.28.3): an LF-only `^---\n` on a `---\r\n` (Windows/autocrlf)
    // page reports NO frontmatter → the autofix prepended a SECOND block (corruption
    // on every reindex). BOM-tolerant (D054, same corruption class): a leading U+FEFF
    // shifts the fence to offset 1. hasFrontmatterFence detects both.
    if (!hasFrontmatterFence(content)) {
      issues.push({
        type: 'missing_frontmatter',
        severity: 'warning',
        path: filePath,
        message: `Missing YAML frontmatter: ${slug}`,
        autofix: 'add_frontmatter',
      });
    } else {
      if (isMalformedFrontmatter(content)) {
        // Invalid `related:`/`tags:` YAML produced by the graph projector's old
        // emitter: the bracketless multi-item form `related: [[a]], [[b]]` (a real
        // YAML parser rejects it) or orphaned block-list children left under an
        // inline value. The in-tree regex readers tolerate these, so they slipped
        // past every prior lint run — this detector + normalize autofix is the
        // durable backstop AND the remediation path for already-corrupted pages.
        issues.push({
          type: 'malformed_frontmatter',
          severity: 'warning',
          path: filePath,
          message: `Invalid related:/tags: YAML frontmatter — run with autofix to normalize: ${slug}`,
          autofix: 'normalize_frontmatter',
        });
      }
      // Node-shape convergence: frontmatter present but missing required fields.
      // The patch fills ONLY absent fields (never overwrites, never bumps
      // updated:, never invents created='today') — so a page that merely lacks
      // created/tags/etc. reaches canonical shape. Generated MOCs (projects/
      // themes/) own their frontmatter and are regenerated, so they are exempt.
      if (!/[/\\](projects|themes)[/\\]/.test(filePath) && isIncompleteFrontmatter(content)) {
        issues.push({
          type: 'incomplete_frontmatter',
          severity: 'warning',
          path: filePath,
          message: `Frontmatter missing required field(s) — run with autofix to patch: ${slug}`,
          autofix: 'patch_frontmatter',
        });
      }
    }

    const datePrefix = slug.match(/^\d{4}-\d{2}-\d{2}-/);
    if (datePrefix) {
      issues.push({
        type: 'stale_page',
        severity: 'warning',
        path: filePath,
        message: `Date-prefixed filename should be renamed: ${slug}`,
        autofix: 'rename_strip_date',
      });
    }

    if (isSessionNarrative(content, slug)) {
      issues.push({
        type: 'stale_page',
        severity: 'warning',
        path: filePath,
        message: `Session-narrative page "${slug}" — content should be merged into its parent entity`,
        autofix: 'merge_into_entity',
      });
    }
  }

  const allSlugs = new Set(allPages.map(p => basename(p, '.md')));
  for (const doc of parsedDocs) {
    for (const rawRef of doc.related) {
      // [[target|alias]] resolves to its target — split before checking (same alias rule as
      // graph-migrate.sh). Without this, a valid aliased link is a false-positive broken_link.
      const ref = rawRef.split('|')[0].trim();
      if (ref && !allSlugs.has(ref)) {
        issues.push({
          type: 'broken_link',
          severity: 'warning',
          path: doc.path,
          message: `Broken wiki-link [[${ref}]] — no matching page`,
        });
      }
    }
  }

  // Relation visibility (node-shape convergence): WARN where a page's `related:`
  // frontmatter disagrees with the current-valid edge graph. DETECTION ONLY —
  // the projector (graph-project.ts) is the sole writer of related:, so auto-
  // rewriting here would fight it and could mass-delete hand-authored links.
  // Skipped entirely when the graph is not enabled (no edges.jsonl). After a
  // reindex the projector has already reconciled related:, so this mostly
  // surfaces drift on the standalone-lint / pre-projection (dream staging) path.
  try {
    if (edgeRecords.length > 0) {
      const nowIso = new Date().toISOString();
      const current = foldToCurrent(edgeRecords).filter(e => validAt(e, nowIso));
      const expected = new Map<string, Set<string>>();
      const addRel = (a: string, b: string) => {
        if (!expected.has(a)) expected.set(a, new Set());
        expected.get(a)!.add(b);
      };
      for (const e of current) { addRel(e.from, e.to); addRel(e.to, e.from); }
      for (const doc of parsedDocs) {
        const s = basename(doc.path, '.md');
        if (/[/\\](projects|themes)[/\\]/.test(doc.path)) continue;
        const want = expected.get(s) ?? new Set<string>();
        const have = new Set(doc.related.map(r => r.split('|')[0].trim()).filter(Boolean));
        // only compare against live endpoints — a drifted edge to a deleted page
        // is the projector's concern, not a page-level drift warning
        const wantLive = new Set([...want].filter(t => allSlugs.has(t)));
        const missing = [...wantLive].filter(t => !have.has(t));
        const extra = [...have].filter(t => !wantLive.has(t));
        if (missing.length || extra.length) {
          issues.push({
            type: 'related_drift',
            severity: 'warning',
            path: doc.path,
            message: `related: drifted from the edge graph for ${s}` +
              (missing.length ? ` — missing [${missing.join(', ')}]` : '') +
              (extra.length ? ` — stale [${extra.join(', ')}]` : '') +
              ` (run knowledge_reindex to re-project)`,
          });
        }
      }
    }
  } catch { /* graph dir absent / unreadable — no drift check */ }

  for (const [slug, paths] of slugMap) {
    if (paths.length > 1) {
      issues.push({
        type: 'duplicate_slug',
        severity: 'error',
        path: paths.join(', '),
        message: `Duplicate slug "${slug}" in: ${paths.map(p => relative(wikiDir, p)).join(', ')}`,
        autofix: 'merge',
      });
    }
  }

  try {
    const rootFiles = await fs.readdir(knowledgeDir, { withFileTypes: true });
    for (const entry of rootFiles) {
      if (entry.isFile() && entry.name.endsWith('.md') && entry.name !== 'README.md') {
        const rootPath = join(knowledgeDir, entry.name);
        issues.push({
          type: 'root_orphan',
          severity: 'error',
          path: rootPath,
          message: `Orphan file at knowledge root — should be in wiki/ or removed: ${entry.name}`,
          autofix: 'move_or_remove',
        });
      }
    }
  } catch { /* knowledgeDir may not exist */ }

  if (opts.autofix) {
    for (const issue of issues) {
      if (issue.autofix === 'remove' && issue.type === 'empty_page') {
        try {
          // D066: re-stat + re-read right before unlinking — the issue was recorded during the
          // scan pass above, which can finish long after this page was observed empty. Skip
          // anything too young (possibly mid-write) and re-verify it is STILL empty now.
          const stat = await fs.stat(issue.path);
          if (Date.now() - stat.mtimeMs < EMPTY_PAGE_MIN_AGE_MS) continue;
          const recheck = await fs.readFile(issue.path, 'utf-8');
          if (recheck.trim()) continue;   // populated since the scan — do not delete
          await fs.unlink(issue.path);
          fixed++;
        } catch { /* already gone */ }
      }
      if (issue.autofix === 'move_or_remove' && issue.type === 'root_orphan') {
        try {
          const stat = await fs.stat(issue.path);
          if (stat.size === 0) {
            await fs.unlink(issue.path);
            fixed++;
          }
        } catch { /* already gone */ }
      }
      if (issue.autofix === 'add_frontmatter' && issue.type === 'missing_frontmatter') {
        try {
          await addFrontmatter(issue.path, wikiDir);
          fixed++;
        } catch { /* skip pages we can't write */ }
      }
      if (issue.autofix === 'normalize_frontmatter' && issue.type === 'malformed_frontmatter') {
        try {
          if (await normalizeFrontmatter(issue.path)) fixed++;
        } catch { /* skip pages we can't write */ }
      }
      if (issue.autofix === 'patch_frontmatter' && issue.type === 'incomplete_frontmatter') {
        try {
          if (await patchFrontmatter(issue.path, wikiDir, graphEnabled)) fixed++;
        } catch { /* skip pages we can't write */ }
      }
    }
  }

  return { issues, fixed, pagesScanned: allPages.length };
}

// Frontmatter present but missing one or more canonical required fields.
function isIncompleteFrontmatter(content: string): boolean {
  const m = matchFrontmatter(content);
  if (!m) return false;
  return REQUIRED_FM_FIELDS.some(k => !new RegExp(`^${k}:`, 'm').test(m.fm));
}

// Patch ONLY the absent required fields onto an existing frontmatter block,
// preserving every existing field verbatim. Derivation mirrors addFrontmatter
// (title from H1/slug, type from folder, created from body-date/slug/mtime) —
// but `updated` derives from FILE MTIME, never "today", so shaping a page never
// re-dates it (the churn/provenance risk). Returns true if the file changed.
async function patchFrontmatter(filePath: string, wikiDir: string, graphEnabled = false): Promise<boolean> {
  const original = await fs.readFile(filePath, 'utf-8');
  const m = matchFrontmatter(original);
  if (!m) return false;
  const fmBody = m.fm;
  const missing = REQUIRED_FM_FIELDS.filter(k => !new RegExp(`^${k}:`, 'm').test(fmBody));
  if (missing.length === 0) return false;

  const slug = basename(filePath, '.md');
  const body = m.body;
  let mtimeDate: string;
  try { mtimeDate = (await fs.stat(filePath)).mtime.toISOString().slice(0, 10); }
  catch { mtimeDate = new Date().toISOString().slice(0, 10); }

  const derive = (k: string): string => {
    switch (k) {
      case 'title': {
        const h = body.match(/^#\s+(.+?)\s*$/m);
        return `title: "${h ? h[1].trim().replace(/"/g, "'") : slug.replace(/-/g, ' ')}"`;
      }
      case 'description': return 'description: ""';
      case 'type': {
        const seg = relative(wikiDir, filePath).split(/[/\\]/)[0];
        return `type: ${KNOWN_CATEGORIES.has(seg) ? seg : 'state'}`;
      }
      case 'created': {
        const d = body.match(/\*\*Date(?:\s*\w+)?\*\*:\s*(\d{4}-\d{2}-\d{2})/i);
        const sd = slug.match(/^(\d{4}-\d{2}-\d{2})/) || slug.match(/(\d{4}-\d{2}-\d{2})$/);
        return `created: ${d ? d[1] : sd ? sd[1] : mtimeDate}`;
      }
      case 'updated': return `updated: ${mtimeDate}`;   // mtime, NEVER today
      case 'tags': return 'tags: []';
      case 'related': {
        // P2: on a graph-enabled corpus the projector OWNS related: — emit `[]`
        // so the projector and validator agree (no body-derived value for the
        // projector to overwrite → no reindex oscillation). Only body-derive when
        // the graph is OFF (then frontmatter related: is the only relatedness source).
        if (graphEnabled) return 'related: []';
        const links = body.match(/\[\[([^\]]+)\]\]/g) || [];
        const rel = [...new Set(links.map(l => l.slice(2, -2).split('|')[0].trim())
          .filter(r => /^[a-z0-9][a-z0-9-]*$/i.test(r)))];
        return `related: [${rel.join(', ')}]`;
      }
      default: return '';
    }
  };

  const newFm = `${fmBody}\n${missing.map(derive).join('\n')}`;
  const next = replaceFrontmatter(original, newFm);
  if (next === original) return false;
  await fs.writeFile(filePath, next, 'utf-8');
  return true;
}

// Single source of truth: every recognized wiki category (kb-schema.json via kb-schema.ts).
const KNOWN_CATEGORIES = new Set(ALL_CATEGORIES);

export async function addFrontmatter(filePath: string, wikiDir: string): Promise<void> {
  const original = await fs.readFile(filePath, 'utf-8');
  // Defensive: if frontmatter snuck in between scan and write, leave it alone.
  // BOM-tolerant (D054): without this, a BOM'd page that already has valid frontmatter
  // slipped past this guard and got a SECOND block prepended on top of the first.
  if (hasFrontmatterFence(original)) return;

  const slug = basename(filePath, '.md');

  // Title: first '# Heading' line, else slug-as-title.
  const headingMatch = original.match(/^#\s+(.+?)\s*$/m);
  const title = headingMatch
    ? headingMatch[1].trim().replace(/"/g, "'")
    : slug.replace(/-/g, ' ');

  // Type: folder segment directly under wiki/.
  const relPath = relative(wikiDir, filePath);
  const firstSeg = relPath.split(/[/\\]/)[0];
  const type = KNOWN_CATEGORIES.has(firstSeg) ? firstSeg : 'state';

  // Created: a `**Date**: YYYY-MM-DD` line in the body wins; else date-prefixed slug;
  // else file mtime. We never invent dates from "today" — that would lie about provenance.
  let created = '';
  const dateLine = original.match(/\*\*Date(?:\s*\w+)?\*\*:\s*(\d{4}-\d{2}-\d{2})/i);
  if (dateLine) {
    created = dateLine[1];
  } else {
    const slugDate = slug.match(/^(\d{4}-\d{2}-\d{2})/) || slug.match(/(\d{4}-\d{2}-\d{2})$/);
    if (slugDate) {
      created = slugDate[1];
    } else {
      try {
        const stat = await fs.stat(filePath);
        created = stat.mtime.toISOString().slice(0, 10);
      } catch {
        created = new Date().toISOString().slice(0, 10);
      }
    }
  }
  const updated = new Date().toISOString().slice(0, 10);

  // Related: any [[wiki-link]] tokens already in the body (deduped).
  const linkMatches = original.match(/\[\[([^\]]+)\]\]/g) || [];
  const related = [...new Set(
    linkMatches
      .map(l => l.slice(2, -2).trim())
      // Filter out matches that are clearly not wiki slugs (spaces, regex metachars, etc.)
      .filter(r => /^[a-z0-9][a-z0-9-]*$/i.test(r))
  )];

  const fm =
    `---\n` +
    `title: "${title}"\n` +
    `description: ""\n` +
    `type: ${type}\n` +
    `created: ${created}\n` +
    `updated: ${updated}\n` +
    `tags: []\n` +
    `related: [${related.join(', ')}]\n` +
    `---\n\n`;

  await fs.writeFile(filePath, fm + original, 'utf-8');
}

// Detect frontmatter a real YAML parser rejects — the durable backstop for the
// whole class of corruption the in-tree tolerant regex readers silently mask.
// Earlier this matched only two hard-coded broken shapes (orphaned block-list
// children; bracketless multi-item wiki-links `related: [[a]], [[b]]`), so live
// failures the regex didn't anticipate slipped through every lint run:
//   - duplicated mapping key  (`updated: x` twice → the reader returns the STALE
//     first value, corrupting the recency boost)
//   - bad indentation from an unquoted value containing a colon
//     (`description: … (generated from project: facets).`)
// The fix is to use the SAME standard the test-oracle uses — `yaml.load()` —
// so the runtime detector can never again diverge from real YAML validity. A
// clean `related: [a, b]` / `related: []` / `related: [[a]]` (valid nested
// array) all parse, so valid pages are never churned.
function isMalformedFrontmatter(content: string): boolean {
  const m = matchFrontmatter(content);
  if (!m) return false;
  try {
    yaml.load(m.fm);   // throws (YAMLException) on any invalid frontmatter
    return false;
  } catch {
    return true;
  }
}

// Collapse duplicate top-level frontmatter keys, keeping each key's LAST
// occurrence (and its owned indented block-list continuation). Shallow by
// design — frontmatter is a flat key: value map, so a key appearing at column 0
// twice is always an error, and "keep last" preserves the freshest value (the
// duplicate-`updated:` bug). A non-key line (stray/blank) is passed through
// untouched; a page without duplicates round-trips byte-identically.
function dedupeTopLevelKeys(fm: string): string {
  const lines = fm.split('\n');
  type Seg = { key: string | null; start: number; end: number };
  const segs: Seg[] = [];
  let i = 0;
  while (i < lines.length) {
    const km = lines[i].match(/^([A-Za-z_][\w.-]*):/);
    if (km) {
      let j = i + 1;
      while (j < lines.length && /^[ \t]/.test(lines[j])) j++;  // owned continuation
      segs.push({ key: km[1], start: i, end: j });
      i = j;
    } else {
      segs.push({ key: null, start: i, end: i + 1 });
      i++;
    }
  }
  const lastIdxOf = new Map<string, number>();
  segs.forEach((s, idx) => { if (s.key) lastIdxOf.set(s.key, idx); });
  const out: string[] = [];
  segs.forEach((s, idx) => {
    if (s.key && lastIdxOf.get(s.key) !== idx) return;   // drop earlier duplicate
    for (let k = s.start; k < s.end; k++) out.push(lines[k]);
  });
  return out.join('\n');
}

// Re-serialize `related:` and `tags:` to the canonical β form `key: [a, b]` (valid
// YAML, read correctly by extractYamlList's inline branch, identical to the
// addFrontmatter emitter), consuming any orphaned block-list children. Scoped to
// the FIRST frontmatter block so a body line starting `related:` is never touched.
// Returns true if the file changed. NEVER adds or removes non-list fields —
// stripping unknown frontmatter would risk deleting legitimate user data.
async function normalizeFrontmatter(filePath: string): Promise<boolean> {
  const content = await fs.readFile(filePath, 'utf-8');
  const m = matchFrontmatter(content);
  if (!m) return false;
  let fm = m.fm;
  // Repair the duplicate-mapping-key class first (e.g. `updated:` written twice
  // — the regex reader returned the STALE first value). Collapse each duplicated
  // top-level key to its LAST occurrence (the freshest value), preserving every
  // key's owned indented continuation. A page with no duplicates is unchanged.
  fm = dedupeTopLevelKeys(fm);
  for (const key of ['related', 'tags']) {
    const blockRe = new RegExp(`^${key}:[^\\n]*(?:\\n[ \\t]+-[^\\n]*)*$`, 'm');
    if (!blockRe.test(fm)) continue;
    const slugs = extractYamlList(fm, key);   // tolerant read of whatever broken shape exists
    fm = fm.replace(blockRe, () => `${key}: [${slugs.join(', ')}]`);
  }
  // Unquoted scalar with an embedded ": " (e.g. `description: Open in kiri-os: the P0 batch`,
  // written when sb_append truncated the closing quote) parses as a nested mapping → YAML
  // throws. The two steps above never touch it, so 9 live pages re-reported malformed on EVERY
  // validate while autofix claimed to handle them — the self-heal never converged (measured on
  // the real KB 2026-08-23: 45 issues before autofix, 45 after). If the block still fails to
  // parse, quote each offending single-line scalar; re-parse to confirm before writing.
  try { yaml.load(fm); } catch {
    const repaired = fm.split('\n').map(line => {
      const m2 = line.match(/^([A-Za-z_][A-Za-z0-9_-]*):[ \t]+(.+)$/);
      if (!m2) return line;
      // Repair only a line that itself fails to parse (embedded ": " in an unquoted scalar,
      // or unescaped inner quotes inside a quoted one — e.g. `head -c "$max"` in a "…" value).
      try { yaml.load(line); return line; } catch { /* fall through to re-quote */ }
      let v = m2[2].trim();
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) v = v.slice(1, -1);
      return `${m2[1]}: ${JSON.stringify(v)}`;
    }).join('\n');
    try { yaml.load(repaired); fm = repaired; } catch { /* still broken — leave for a human */ }
  }
  const next = replaceFrontmatter(content, fm);
  if (next === content) return false;
  await fs.writeFile(filePath, next, 'utf-8');
  return true;
}

function isSessionNarrative(content: string, slug: string): boolean {
  const sessionSignals = [
    /^##\s+(key\s+)?findings?\b/im,
    /^##\s+files\s+(changed|touched)\b/im,
    /^##\s+review\s+approach\b/im,
    /^##\s+open\s+items?\b/im,
    /\bMR\s+!\d+\b/i,
    /\bsession\b.*\bsummary\b/i,
    /\bin\s+this\s+session\b/i,
    /\bfriction\s+signals?:\s*\d+/i,
    /\buser\s+turns?:\s*\d+/i,
  ];
  const slugSignals = [
    /^mr\d+-/,
    /^mr-\d+/,
    /-mr\d+$/,
    /-session$/,
    /-review$/,
    /-upgrade$/,
    /-build$/,
    /-migration$/,
  ];

  let score = 0;
  for (const re of sessionSignals) {
    if (re.test(content)) score++;
  }
  for (const re of slugSignals) {
    if (re.test(slug)) score++;
  }
  return score >= 3;
}
