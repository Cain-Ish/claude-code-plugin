import { promises as fs } from 'fs';
import { join, basename, dirname, relative } from 'path';
import { parseDoc, ParsedDoc, extractYamlList } from './knowledge-search.js';
import { parseAiBlock, validateAiBlock, stripAiBlock, schemaFor } from './ai-block.js';
import { ALL_CATEGORIES } from '../constants/kb-schema.js';

// A structured page with this much prose (non-frontmatter, marked regions stripped) but no
// ai-block is a backfill candidate; shorter pages are legitimate stubs, exempt. Env-overridable
// in lockstep with kb-ai-block-candidates.sh / lint Check 4 (default 200).
const AI_BLOCK_MIN_PROSE = Number(process.env.SB_AI_BLOCK_MIN_PROSE) || 200;

export interface ValidationIssue {
  type: 'orphan_file' | 'broken_link' | 'missing_frontmatter' | 'malformed_frontmatter' | 'duplicate_slug' | 'stale_page' | 'empty_page' | 'root_orphan' | 'ai_block_incomplete' | 'ai_block_missing';
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
  opts: { autofix?: boolean } = {}
): Promise<ValidationResult> {
  const wikiDir = join(knowledgeDir, 'wiki');
  const issues: ValidationIssue[] = [];
  let fixed = 0;

  const allPages = await collectAllPages(wikiDir);
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
      const prose = stripAiBlock(content)
        .replace(/<!--\s*graph:begin[\s\S]*?graph:end\s*-->/g, '')
        .replace(/<!--\s*theme:begin[\s\S]*?theme:end\s*-->/g, '')
        .replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, '');
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

    const fmMatch = content.match(/^---\n/);
    if (!fmMatch) {
      issues.push({
        type: 'missing_frontmatter',
        severity: 'warning',
        path: filePath,
        message: `Missing YAML frontmatter: ${slug}`,
        autofix: 'add_frontmatter',
      });
    } else if (isMalformedFrontmatter(content)) {
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
    }
  }

  return { issues, fixed, pagesScanned: allPages.length };
}

// Single source of truth: every recognized wiki category (kb-schema.json via kb-schema.ts).
const KNOWN_CATEGORIES = new Set(ALL_CATEGORIES);

export async function addFrontmatter(filePath: string, wikiDir: string): Promise<void> {
  const original = await fs.readFile(filePath, 'utf-8');
  // Defensive: if frontmatter snuck in between scan and write, leave it alone.
  if (/^---\n/.test(original)) return;

  const slug = basename(filePath, '.md');

  // Title: first '# Heading' line, else slug-as-title.
  const headingMatch = original.match(/^#\s+(.+?)\s*$/m);
  const title = headingMatch
    ? headingMatch[1].trim().replace(/"/g, "'")
    : slug.replace(/-/g, ' ');

  // Type: folder segment directly under wiki/.
  const relPath = relative(wikiDir, filePath);
  const firstSeg = relPath.split('/')[0];
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

// Detect the two invalid `related:`/`tags:` frontmatter shapes the old projector
// emitted, scoped to the FIRST frontmatter block. Both break a real YAML parser
// while the in-tree regex readers silently tolerate them.
//   (a) orphaned block-list children under an inline value:  related: [[a]]\n  - b
//   (b) bracketless multi-item wiki-links:                   related: [[a]], [[b]]
// A single `related: [[a]]` (valid nested-array YAML) and a clean `related: [a, b]`
// or `related: []` are NOT flagged — keeps the validator from churning valid pages.
function isMalformedFrontmatter(content: string): boolean {
  const m = content.match(/^---\n([\s\S]*?)\n---/);
  if (!m) return false;
  const fm = m[1];
  const orphanBlockList = /^(?:related|tags):[ \t]+\S[^\n]*\n[ \t]+-[ \t]/m.test(fm);
  const bracketlessMulti = /^(?:related|tags):[^\n]*\]\][ \t]*,/m.test(fm);
  return orphanBlockList || bracketlessMulti;
}

// Re-serialize `related:` and `tags:` to the canonical β form `key: [a, b]` (valid
// YAML, read correctly by extractYamlList's inline branch, identical to the
// addFrontmatter emitter), consuming any orphaned block-list children. Scoped to
// the FIRST frontmatter block so a body line starting `related:` is never touched.
// Returns true if the file changed. NEVER adds or removes non-list fields —
// stripping unknown frontmatter would risk deleting legitimate user data.
async function normalizeFrontmatter(filePath: string): Promise<boolean> {
  const content = await fs.readFile(filePath, 'utf-8');
  const m = content.match(/^---\n([\s\S]*?)\n---/);
  if (!m) return false;
  let fm = m[1];
  for (const key of ['related', 'tags']) {
    const blockRe = new RegExp(`^${key}:[^\\n]*(?:\\n[ \\t]+-[^\\n]*)*$`, 'm');
    if (!blockRe.test(fm)) continue;
    const slugs = extractYamlList(fm, key);   // tolerant read of whatever broken shape exists
    fm = fm.replace(blockRe, () => `${key}: [${slugs.join(', ')}]`);
  }
  const next = content.replace(/^---\n[\s\S]*?\n---/, () => `---\n${fm}\n---`);
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

async function collectAllPages(dir: string, acc: string[] = []): Promise<string[]> {
  try {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    for (const e of entries) {
      const p = join(dir, e.name);
      if (e.isDirectory()) await collectAllPages(p, acc);
      else if (e.isFile() && e.name.endsWith('.md') && e.name !== 'index.md') acc.push(p);
    }
  } catch { /* dir doesn't exist */ }
  return acc;
}
