// Stage B of the P6 quarantine split — the PRIVILEGED, DETERMINISTIC writer.
//
// Consumes the quarantined summarizer's validated candidate facts and applies them to a
// dream's STAGING wiki (never live; never anywhere else — every write is path-guarded).
// No LLM, no network: target resolution is a local BM25 reconcile over the staging tree
// (mem0-style ADD/UPDATE/NOOP), page content is rendered verbatim from the fact's
// sanitized fields. Determinism is load-bearing: same facts + same staging → byte-identical
// output (dates derive from the dream id, hashes from fact content — no wall clock).
//
// Netlessness is enforced two ways: on Linux the harness wraps this CLI in
// bwrap --unshare-net (kernel boundary, additive); on every OS the static source-scan in
// consolidate-writer.test.ts forbids network/child-process imports (structural boundary).
import { promises as fs } from 'fs';
import { join, relative, isAbsolute, resolve } from 'path';
import { CandidateFact, KIND_TO_CATEGORY } from './candidate-facts.js';
import { validateSlug, assertWithin, PathGuardError } from '../path-guard.js';
import { slugify } from './raw-inbox.js';
import { matchFrontmatter } from './frontmatter.js';

export interface ApplyReport {
  added: string[];
  updated: string[];
  skipped: { kind: string; reason: string }[];
}

export interface ApplyOpts {
  dreamId: string;
  /** YYYY-MM-DD for created/updated — derived from the dream id, never wall clock. */
  date: string;
}

/**
 * Does this fact belong on an EXISTING page? Deterministic, corpus-independent, and
 * corpus-order-independent: the fact's own slug must match the page's slug exactly, or the
 * page's title tokens must be a subset of the fact's tokens (the fact is *about* that page).
 *
 * This deliberately replaced a BM25 reconcile, which was actively harmful:
 *  - knowledgeSearch returns `score_norm = score / topScore`, so the top hit is ALWAYS 1.0.
 *    Any `score_norm >= threshold` test is therefore vacuous — a single shared token ("the")
 *    was enough to graft an unrelated fact onto whatever page ranked first, and fold-ins apply
 *    to the LIVE wiki unattended. Verified by running the committed bundle, not by reading it.
 *  - BM25 ranking carries a 90-day RECENCY boost, so the same inputs could resolve differently
 *    on different days — breaking Stage B's byte-determinism contract outright.
 * Fold-in means "this page is the corroboration", so an exact, explainable match is the honest
 * bar. Everything else becomes a new page, which the accept gate holds until confirmed.
 */
const TITLE_STOP = new Set(['the', 'a', 'an', 'of', 'and', 'or', 'to', 'for', 'in', 'on', 'is', 'are', 'was', 'were', 'be', 'it', 'its', 'this', 'that', 'with', 'by', 'as', 'at', 'from']);
function titleTokens(s: string): string[] {
  return s.toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length > 2 && !TITLE_STOP.has(t));
}
export function isFoldInMatch(factTitle: string, factClaim: string, pageSlug: string, pageTitle: string): boolean {
  if (slugify(factTitle) === pageSlug) return true;
  const pt = titleTokens(pageTitle);
  if (pt.length === 0) return false;
  const factSet = new Set([...titleTokens(factTitle), ...titleTokens(factClaim)]);
  return pt.every((t) => factSet.has(t));
}

/** djb2 over the fact's identity fields, base36 — the idempotency key. */
export function factHash(f: CandidateFact): string {
  const s = `${f.kind}|${f.claim}`;
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0;
  return (h >>> 0).toString(36);
}

const UNTRUSTED_SECTION = '## Candidate facts (untrusted)';

function titleOf(f: CandidateFact): string {
  if (f.title && f.title.trim()) return f.title.trim();
  const t = f.claim.replace(/\s+/g, ' ').trim().slice(0, 80);
  return t;
}

function sourcesLine(f: CandidateFact, dreamId: string): string {
  const bits = [`captured from ${f.source || 'transcript (unnamed)'}`, `dream ${dreamId}`];
  if (f.confidence) bits.push(`confidence ${f.confidence}`);
  return `- ${bits.join(', ')}`;
}

function renderNewPage(f: CandidateFact, category: string, title: string, hash: string, opts: ApplyOpts): string {
  const description = f.claim.replace(/\s+/g, ' ').trim().slice(0, 140);
  const lines = [
    '---',
    `title: ${title}`,
    `description: ${description}`,
    `type: ${category}`,
    `created: ${opts.date}`,
    `updated: ${opts.date}`,
    'tags: []',
    'related: []',           // explicit empty = authoritative (body links are NOT scraped)
    'provenance: untrusted-derived',
    'origin: dream-summarizer',
    `fact_hash: ${hash}`,
    '---',
    '',
    `# ${title}`,
    '',
    f.claim.trim(),
    '',
  ];
  if (f.evidence && f.evidence.trim()) lines.push(`**Evidence:** ${f.evidence.trim()}`, '');
  lines.push('## Sources', '', sourcesLine(f, opts.dreamId), '');
  return lines.join('\n');
}

async function writeAtomic(path: string, content: string): Promise<void> {
  // Text sibling of atomic-write.ts's atomicWriteJson (that one JSON.stringifies and swallows
  // failures; here a write failure must PROPAGATE so the CLI can fail loud). Clean up the tmp
  // on failure — a leaked `*.tmp.<pid>` inside the staging wiki would be copied to the live
  // wiki by the accept and then linger as an unparseable page.
  const tmp = `${path}.tmp.${process.pid}`;
  try {
    await fs.writeFile(tmp, content);
    await fs.rename(tmp, path);
  } catch (err) {
    await fs.unlink(tmp).catch(() => { /* already gone */ });
    throw err;
  }
}

/**
 * Put a fact bullet INSIDE the untrusted section, at the end of that section — not at EOF.
 * A plain EOF append lands after whatever the page gained later (the generated
 * `<!-- graph:begin -->` dependency block is appended last by the projector), which would
 * leave the bullet outside the section whose label is the reader's only cue that the claim is
 * transcript-derived. Creates the section at EOF when the page has none yet.
 */
export function appendToUntrustedSection(content: string, bullet: string): string {
  const body = content.replace(/\s+$/, '');
  const at = body.indexOf(UNTRUSTED_SECTION);
  if (at === -1) return `${body}\n\n${UNTRUSTED_SECTION}\n\n${bullet}\n`;
  const afterHeading = at + UNTRUSTED_SECTION.length;
  // End of the section = the next top-level heading, else the next generated region, else EOF.
  const rest = body.slice(afterHeading);
  const nextHeading = rest.search(/\n#{1,2} /);
  const nextGenerated = rest.search(/\n<!--\s*(graph|theme|ai):begin/);
  const candidates = [nextHeading, nextGenerated].filter((i) => i !== -1);
  const cut = candidates.length ? afterHeading + Math.min(...candidates) : body.length;
  return `${body.slice(0, cut).replace(/\s+$/, '')}\n${bullet}\n${body.slice(cut).replace(/^\n+/, '\n')}`.replace(/\s+$/, '') + '\n';
}

/** Containment check for an absolute path returned by the search seam. */
function withinWiki(wikiRoot: string, p: string): boolean {
  const rel = relative(resolve(wikiRoot), resolve(p));
  return rel !== '' && !rel.startsWith('..') && !isAbsolute(rel);
}

function bumpUpdated(content: string, date: string): string {
  const fm = matchFrontmatter(content);
  if (!fm) return content;
  const newFm = fm.fm.replace(/^updated:.*$/m, `updated: ${date}`);
  return `---\n${newFm}\n---\n${fm.body}`;
}

/**
 * Apply validated candidate facts to the staging wiki. Deterministic and idempotent:
 * a second run over the same facts + staging is a no-op (facts key by content hash).
 * Every skip carries a reason — the caller surfaces the counts (fail-loud lives there).
 */
export async function applyCandidates(
  stagingRoot: string,
  facts: CandidateFact[],
  opts: ApplyOpts
): Promise<ApplyReport> {
  const report: ApplyReport = { added: [], updated: [], skipped: [] };
  const wikiRoot = join(stagingRoot, 'wiki');

  for (const f of facts) {
    const category = KIND_TO_CATEGORY[f.kind];
    if (!category) {
      // DROPPED, not routed: nothing downstream consumes these yet. Preferences would need the
      // persona-rules lane and relations the live maintainer's edge writer; until one of those
      // reads candidate-facts.json, saying "routed" would be a prose promise with no machine
      // behind it. The fact stays in candidate-facts.json for a future consumer.
      report.skipped.push({ kind: f.kind, reason: `kind '${f.kind}' is not writer-applied — DROPPED this run (no consumer yet: preferences need the persona-rules lane, relations the live maintainer's edge writer)` });
      continue;
    }
    const title = titleOf(f);
    if (!title) { report.skipped.push({ kind: f.kind, reason: 'empty title/claim' }); continue; }
    const hash = factHash(f);

    // Deterministic reconcile over the fact's OWN category dir. Scanning the directory (rather
    // than querying a ranker) keeps this corpus- and order-independent: same facts + same
    // staging => same decisions, byte for byte, on any day.
    let target: string | null = null;
    const catDir = join(wikiRoot, category);
    let pages: string[] = [];
    try { pages = (await fs.readdir(catDir)).filter((n) => n.endsWith('.md') && n !== 'index.md').sort(); }
    catch { pages = []; }
    for (const page of pages) {
      const slug = page.slice(0, -3);
      const p = join(catDir, page);
      let head = '';
      try { head = (await fs.readFile(p, 'utf-8')).slice(0, 600); } catch { continue; }
      const pageTitle = (head.match(/^title:\s*(.+)$/m)?.[1] || slug).replace(/^["']|["']$/g, '').trim();
      if (isFoldInMatch(title, f.claim, slug, pageTitle)) { target = resolve(p); break; }
    }
    if (target && !withinWiki(wikiRoot, target)) {
      report.skipped.push({ kind: f.kind, reason: `resolved target escapes staging wiki: ${target}` });
      continue;
    }

    if (target) {
      const content = await fs.readFile(target, 'utf-8');
      // BOTH markers: a page this writer CREATED carries `fact_hash: <h>` in frontmatter, while
      // a folded-in bullet carries `(fact:<h>)`. Checking only the bullet form meant the second
      // run re-appended a bullet restating the very fact the page was created from — the page
      // then fails byte-idempotency forever after.
      if (content.includes(`(fact:${hash})`) || content.includes(`fact_hash: ${hash}`)) {
        report.skipped.push({ kind: f.kind, reason: `duplicate fact ${hash} (idempotent)` });
        continue;
      }
      const bullet = `- (fact:${hash}) ${f.claim.trim()}${f.evidence ? ` — evidence: ${f.evidence.trim()}` : ''} (${sourcesLine(f, opts.dreamId).slice(2)})`;
      await writeAtomic(target, bumpUpdated(appendToUntrustedSection(content, bullet), opts.date));
      report.updated.push(relative(wikiRoot, target).replace(/\\/g, '/'));
      continue;
    }

    // ADD: deterministic slug; same-slug page with a different hash gets a
    // hash-suffixed slug rather than a clobber.
    let slug = slugify(title);
    try {
      validateSlug(slug);
      let path = assertWithin(wikiRoot, category, `${slug}.md`);
      let existing: string | null = null;
      try { existing = await fs.readFile(path, 'utf-8'); } catch { /* new page */ }
      if (existing !== null) {
        if (existing.includes(`fact_hash: ${hash}`) || existing.includes(`(fact:${hash})`)) {
          report.skipped.push({ kind: f.kind, reason: `duplicate fact ${hash} (idempotent)` });
          continue;
        }
        slug = `${slug}-${hash}`;
        validateSlug(slug);
        path = assertWithin(wikiRoot, category, `${slug}.md`);
        try {
          const clash = await fs.readFile(path, 'utf-8');
          if (clash.includes(`fact_hash: ${hash}`)) {
            report.skipped.push({ kind: f.kind, reason: `duplicate fact ${hash} (idempotent)` });
            continue;
          }
        } catch { /* free */ }
      }
      await fs.mkdir(join(wikiRoot, category), { recursive: true });
      await writeAtomic(path, renderNewPage(f, category, title, hash, opts));
      report.added.push(`${category}/${slug}.md`);
    } catch (err: unknown) {
      if (err instanceof PathGuardError) {
        report.skipped.push({ kind: f.kind, reason: `path guard rejected slug '${slug}': ${err.message}` });
      } else {
        throw err; // real I/O failure — fail loud in the CLI
      }
    }
  }
  return report;
}
