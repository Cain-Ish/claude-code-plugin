import { promises as fs } from 'fs';
import { join } from 'path';

export type PinSection = 'blockers' | 'decisions';
export interface PinToProjectArgs { text: string; slug: string; section: PinSection; brainDir?: string; }
export interface PinToProjectResult { ok: boolean; line_added: string; project_slug: string; reason?: string; }

const SECTION_HEADER = { blockers: '## Open blockers', decisions: '## Recent decisions' } as const;
const ENTRY_PREFIX  = { blockers: '- [active] ',       decisions: '- [decision] ' } as const;

export async function pinToProject(args: PinToProjectArgs): Promise<PinToProjectResult> {
  if (!(args.section in SECTION_HEADER)) {
    return { ok: false, line_added: '', project_slug: args.slug, reason: 'unknown section' };
  }
  const dir = args.brainDir ?? join(process.env.HOME ?? '', '.second-brain');
  const file = join(dir, 'projects', args.slug, 'PROJECT.md');
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
  lines.splice(endIdx, 0, newEntry);
  await fs.writeFile(file, lines.join('\n'), 'utf-8');
  return { ok: true, line_added: newEntry, project_slug: args.slug };
}
