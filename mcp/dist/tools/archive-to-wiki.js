import { promises as fs } from 'fs';
import { join } from 'path';
export async function archiveToWiki(args) {
    const brainDir = args.brainDir ?? join(process.env.HOME ?? '', '.second-brain');
    const knowledgeDir = args.knowledgeDir ?? join(process.env.HOME ?? '', 'knowledge');
    const projectFile = join(brainDir, 'projects', args.slug, 'PROJECT.md');
    const wikiDir = join(knowledgeDir, 'wiki', args.targetCategory, args.slug);
    await fs.mkdir(wikiDir, { recursive: true });
    const content = await fs.readFile(projectFile, 'utf-8');
    const lines = content.split('\n');
    const matchIdx = lines.findIndex(l => l.includes(args.entryText) && l.includes('[resolved]'));
    if (matchIdx < 0) {
        return { ok: false, archived_path: '', reason: 'no [resolved] entry matching text' };
    }
    const date = new Date().toISOString().slice(0, 10);
    const slugSafe = args.entryText.toLowerCase().replace(/[^a-z0-9]+/g, '-').slice(0, 40);
    const archivePath = join(wikiDir, `${date}-${slugSafe}.md`);
    await fs.writeFile(archivePath, `# ${args.entryText}\n\n**Archived:** ${date}\n**From:** projects/${args.slug}/PROJECT.md (section: ${args.sourceSection})\n**Status:** resolved\n`, 'utf-8');
    lines[matchIdx] = `  → wiki/${args.targetCategory}/${args.slug}/${date}-${slugSafe}.md`;
    await fs.writeFile(projectFile, lines.join('\n'), 'utf-8');
    return { ok: true, archived_path: archivePath };
}
//# sourceMappingURL=archive-to-wiki.js.map