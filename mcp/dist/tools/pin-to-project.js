import { promises as fs } from 'fs';
import { join } from 'path';
const SECTION_HEADER = { blockers: '## Open blockers', decisions: '## Recent decisions' };
const ENTRY_PREFIX = { blockers: '- [active] ', decisions: '- [decision] ' };
export async function pinToProject(args) {
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
    for (let i = idx + 1; i < lines.length; i++) {
        if (lines[i].startsWith('## ')) {
            endIdx = i;
            break;
        }
    }
    while (endIdx > idx + 1 && lines[endIdx - 1].trim() === '')
        endIdx--;
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
//# sourceMappingURL=pin-to-project.js.map