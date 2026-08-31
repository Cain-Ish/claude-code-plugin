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
export interface PinToProjectResult { ok: boolean; line_added: string; project_slug: string; reason?: string; }

const SECTION_HEADER = { blockers: '## Open blockers', decisions: '## Recent decisions' } as const;
const ENTRY_PREFIX  = { blockers: '- [active] ',       decisions: '- [decision] ' } as const;

// Core text of a section bullet for dedup: strip "- ", optional [YYYY-MM-DD], optional
// marker, and a trailing "(why: …)" suffix — so re-pinning the same decision with
// different reasoning is still a dup, and dated entries dedupe against legacy undated ones.
function bulletCore(line: string): string {
  return line
    .replace(/^- /, '')
    .replace(/^\[\d{4}-\d{2}-\d{2}\] /, '')
    .replace(/^\[(active|resolved|stale|decision|pinned|superseded)\] /, '')
    .replace(/ \(why: .*\)$/, '')
    .trim();
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
  const trimmed = args.text.trim();

  // Decisions are date-first ("- [YYYY-MM-DD] [decision] …") so merge-project-update.sh's
  // mark_stale sweep (matches `^- \[20YY-MM-DD\]`) can age them; undated pins were immortal.
  let newEntry: string;
  if (args.section === 'decisions') {
    const date = new Date().toISOString().slice(0, 10);
    let suffix = '';
    const why = args.reasoning?.trim();
    const rej = args.rejected?.trim();
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

  // Dedupe within section bounds [idx+1, endIdx) on the bullet CORE (date/marker/why
  // stripped) so a dated pin dedupes against a legacy undated entry and vice versa.
  for (let i = idx + 1; i < endIdx; i++) {
    if (lines[i].startsWith('- ') && bulletCore(lines[i]) === trimmed) {
      return { ok: true, line_added: lines[i], project_slug: args.slug, reason: 'already present' };
    }
  }

  // Explicit supersession (decisions only): mark — never delete — the first
  // not-yet-superseded bullet containing the given substring (case-insensitive).
  let reason: string | undefined;
  if (args.section === 'decisions' && args.supersedes?.trim()) {
    const needle = args.supersedes.trim().toLowerCase();
    let marked = false;
    for (let i = idx + 1; i < endIdx; i++) {
      if (!lines[i].startsWith('- ') || lines[i].startsWith('- [superseded] ')) continue;
      if (lines[i].toLowerCase().includes(needle)) {
        lines[i] = `- [superseded] ${lines[i].slice(2)}`;
        marked = true;
        break;
      }
    }
    if (!marked) reason = 'supersedes target not found';
  }

  lines.splice(endIdx, 0, newEntry);
  await fs.writeFile(file, lines.join('\n'), 'utf-8');
  return reason
    ? { ok: true, line_added: newEntry, project_slug: args.slug, reason }
    : { ok: true, line_added: newEntry, project_slug: args.slug };
}
