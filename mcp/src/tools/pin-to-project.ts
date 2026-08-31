import { promises as fs } from 'fs';
import { join } from 'path';
import { assertWithin, validateSlug, PathGuardError } from '../path-guard.js';
import { resolveBrainDir } from '../brain-paths.js';

export type PinSection = 'blockers' | 'decisions';
export interface PinToProjectArgs {
  text: string; slug: string; section: PinSection; brainDir?: string;
  /** decisions only: why this was chosen — rendered as "(why: …)" */
  reasoning?: string;
  /** decisions only: the alternative not taken and why — rendered inside the suffix */
  rejected?: string;
  /** decisions only: substring of an earlier decision bullet this one reverses;
   *  the old bullet is prefixed "- [superseded] " (marked, never deleted). */
  supersedes?: string;
}
export interface PinToProjectResult {
  ok: boolean; line_added: string; project_slug: string; reason?: string;
  /** present iff `supersedes` was requested: whether a target bullet was actually
   *  marked. A typed discriminant so an unmet supersedes can never masquerade as
   *  full success behind ok:true. */
  superseded?: boolean;
}

const SECTION_HEADER = { blockers: '## Open blockers', decisions: '## Recent decisions' } as const;
const ENTRY_PREFIX  = { blockers: '- [active] ',       decisions: '- [decision] ' } as const;

// Flatten model-supplied free text before it is spliced into PROJECT.md — the file is
// auto-injected into every future SessionStart, so an embedded newline would let a single
// call forge "## Section" headers / markers into that context (memory-poisoning primitive;
// 0.48.0 security review). Same discipline as merge_handoff's jq gsub("[`\r\n]"; " ") in
// merge-project-update.sh, plus a per-field length cap.
function flattenField(s: string | undefined, cap: number): string {
  if (!s) return '';
  // NFC-normalize so visually-identical text in different Unicode forms dedupes and
  // supersedes-matches consistently regardless of the caller's input method.
  return s.normalize('NFC').replace(/[\r\n`]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, cap);
}

// A supersedes needle must be long enough to plausibly name ONE earlier decision —
// raw .includes() with a short/generic needle would silently demote an unrelated
// (possibly safety-relevant) bullet, which the hot tier then stops rendering.
const SUPERSEDES_MIN_NEEDLE = 8;

// Core text of a section bullet for dedup and supersedes matching: strip "- ", then
// every leading [YYYY-MM-DD]/[marker] token IN ANY ORDER (mark_stale and the supersede
// marker PREPEND, yielding "- [stale] [DATE] [decision] …" / "- [superseded] [DATE] …"),
// then the trailing "(why: …)" metadata suffix — so supersedes needles can only match
// the decision TEXT, never the reasoning/rejected metadata, and dated entries dedupe
// against legacy undated ones.
function bulletCore(line: string): string {
  let s = line.normalize('NFC').replace(/^- /, '');
  let prev;
  do {
    prev = s;
    s = s
      .replace(/^\[\d{4}-\d{2}-\d{2}\] /, '')
      .replace(/^\[(active|resolved|stale|decision|pinned|superseded)\] /, '');
  } while (s !== prev);
  return s.replace(/ \(why: .*\)$/, '').trim();
}

export async function pinToProject(args: PinToProjectArgs): Promise<PinToProjectResult> {
  if (!(args.section in SECTION_HEADER)) {
    return { ok: false, line_added: '', project_slug: args.slug, reason: 'unknown section' };
  }
  // Path-traversal hardening (G-MCP-1).
  try {
    validateSlug(args.slug);
  } catch (e) {
    if (e instanceof PathGuardError) {
      return { ok: false, line_added: '', project_slug: args.slug, reason: `invalid slug: ${e.message}` };
    }
    throw e;
  }
  const dir = resolveBrainDir(args.brainDir);
  let file: string;
  try {
    file = assertWithin(dir, 'projects', args.slug, 'PROJECT.md');
  } catch (e) {
    if (e instanceof PathGuardError) {
      return { ok: false, line_added: '', project_slug: args.slug, reason: `path traversal blocked: ${e.message}` };
    }
    throw e;
  }
  const content = await fs.readFile(file, 'utf-8');
  const sectionHeader = SECTION_HEADER[args.section];
  const trimmed = flattenField(args.text, 400);
  if (!trimmed) {
    return { ok: false, line_added: '', project_slug: args.slug, reason: 'empty text after sanitization' };
  }

  // Decisions are date-first ("- [YYYY-MM-DD] [decision] …") so merge-project-update.sh's
  // mark_stale sweep (matches `^- \[20YY-MM-DD\]`) can age them; undated pins were immortal.
  let newEntry: string;
  if (args.section === 'decisions') {
    const date = new Date().toISOString().slice(0, 10);
    let suffix = '';
    const why = flattenField(args.reasoning, 200);
    const rej = flattenField(args.rejected, 200);
    if (why && rej) suffix = ` (why: ${why}; rejected: ${rej})`;
    else if (why)   suffix = ` (why: ${why})`;
    else if (rej)   suffix = ` (why: unstated; rejected: ${rej})`;
    newEntry = `- [${date}] [decision] ${trimmed}${suffix}`;
  } else {
    newEntry = `${ENTRY_PREFIX[args.section]}${trimmed}`;
  }

  const lines = content.split('\n');
  const idx = lines.findIndex(line => line.trim() === sectionHeader);
  if (idx < 0) {
    return { ok: false, line_added: '', project_slug: args.slug, reason: `section ${sectionHeader} not found` };
  }
  let endIdx = lines.length;
  for (let i = idx + 1; i < lines.length; i++) { if (lines[i].startsWith('## ')) { endIdx = i; break; } }
  while (endIdx > idx + 1 && lines[endIdx - 1].trim() === '') endIdx--;

  // Comparison core of the NEW text: apply the same trailing-suffix strip bulletCore
  // applies to stored lines, so a text that legitimately ends in " (why: …)" still
  // dedupes symmetrically against its own stored form.
  const newCore = trimmed.replace(/ \(why: .*\)$/, '').trim();

  // Explicit supersession (decisions only) runs BEFORE the dedup check: a duplicate
  // re-pin that also names a supersedes target must still mark that target (idempotent
  // retries would otherwise silently drop the marking). The needle matches the bullet
  // CORE only — never the (why:/rejected:) metadata, so reasoning text about an
  // alternative cannot get an unrelated decision marked. Mark, never delete; never
  // the bullet that IS this pin.
  let reason: string | undefined;
  let marked = false;
  const supersedesRequested = !!flattenField(args.supersedes, 200);
  const needle = flattenField(args.supersedes, 200).toLowerCase();
  if (args.section === 'decisions' && needle) {
    if (needle.length < SUPERSEDES_MIN_NEEDLE) {
      reason = `supersedes needle too short (<${SUPERSEDES_MIN_NEEDLE} chars) — nothing marked`;
    } else {
      for (let i = idx + 1; i < endIdx; i++) {
        if (!lines[i].startsWith('- ') || lines[i].startsWith('- [superseded] ')) continue;
        const core = bulletCore(lines[i]);
        if (core === newCore) continue; // never self-supersede
        if (core.toLowerCase().includes(needle)) {
          lines[i] = `- [superseded] ${lines[i].slice(2)}`;
          marked = true;
          break;
        }
      }
      if (!marked) reason = 'supersedes target not found';
    }
  }

  // Dedupe within section bounds [idx+1, endIdx) on the bullet CORE (date/marker/why
  // stripped) so a dated pin dedupes against a legacy undated entry and vice versa.
  // [superseded]/[stale] bullets are deliberately NOT dedup targets — same semantics
  // as the bash merge path (insert_bullet + detect_supersede): a superseded decision
  // may be legitimately re-pinned as a fresh ACTIVE decision (the flip-flop case).
  for (let i = idx + 1; i < endIdx; i++) {
    if (!lines[i].startsWith('- ')) continue;
    if (lines[i].startsWith('- [superseded] ') || lines[i].startsWith('- [stale] ')) continue;
    if (bulletCore(lines[i]) === newCore) {
      if (marked) await fs.writeFile(file, lines.join('\n'), 'utf-8');
      const dup: PinToProjectResult = { ok: true, line_added: lines[i], project_slug: args.slug, reason: 'already present' };
      if (supersedesRequested) dup.superseded = marked;
      return dup;
    }
  }

  lines.splice(endIdx, 0, newEntry);
  await fs.writeFile(file, lines.join('\n'), 'utf-8');
  const res: PinToProjectResult = { ok: true, line_added: newEntry, project_slug: args.slug };
  if (reason) res.reason = reason;
  if (supersedesRequested) res.superseded = marked;
  return res;
}
