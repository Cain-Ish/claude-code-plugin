import { promises as fs } from 'fs';
import { join } from 'path';
import { assertWithin, validateSlug, PathGuardError, cleanEnvPath } from '../path-guard.js';

export type PinSection = 'blockers' | 'decisions';
export interface PinToProjectArgs { text: string; slug: string; section: PinSection; brainDir?: string; }
export interface PinToProjectResult { ok: boolean; line_added: string; project_slug: string; reason?: string; }

const SECTION_HEADER = { blockers: '## Open blockers', decisions: '## Recent decisions' } as const;
const ENTRY_PREFIX  = { blockers: '- [active] ',       decisions: '- [decision] ' } as const;

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
  const dir = args.brainDir ?? join(cleanEnvPath(process.env.HOME), '.second-brain');
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
  const newEntry = `${ENTRY_PREFIX[args.section]}${args.text.trim()}`;
  const lines = content.split('\n');
  const idx = lines.findIndex(line => line.trim() === sectionHeader);
  if (idx < 0) {
    return { ok: false, line_added: '', project_slug: args.slug, reason: `section ${sectionHeader} not found` };
  }
  let endIdx = lines.length;
  for (let i = idx + 1; i < lines.length; i++) { if (lines[i].startsWith('## ')) { endIdx = i; break; } }
  while (endIdx > idx + 1 && lines[endIdx - 1].trim() === '') endIdx--;

  // Dedupe within section bounds [idx+1, endIdx). Match lines that begin with the
  // section's entry prefix and whose trimmed payload equals the trimmed input text.
  const trimmed = args.text.trim();
  const prefix = ENTRY_PREFIX[args.section];
  for (let i = idx + 1; i < endIdx; i++) {
    if (lines[i].startsWith(prefix) && lines[i].slice(prefix.length).trim() === trimmed) {
      return { ok: true, line_added: lines[i], project_slug: args.slug, reason: 'already present' };
    }
  }

  lines.splice(endIdx, 0, newEntry);
  await fs.writeFile(file, lines.join('\n'), 'utf-8');
  return { ok: true, line_added: newEntry, project_slug: args.slug };
}
