import { promises as fs } from 'fs';
import { join } from 'path';
import { assertWithin, validateSlug, PathGuardError } from '../path-guard.js';
import { resolveBrainDir, resolveKnowledgeDir } from '../brain-paths.js';

export type SourceSection = 'blockers' | 'decisions';
export type TargetCategory = 'issues' | 'decisions';
const ALLOWED_TARGET_CATEGORIES: ReadonlySet<TargetCategory> = new Set<TargetCategory>(['issues', 'decisions']);
export interface ArchiveToWikiArgs {
  slug: string; sourceSection: SourceSection; entryText: string;
  targetCategory: TargetCategory; brainDir?: string; knowledgeDir?: string;
}
export interface ArchiveToWikiResult { ok: boolean; archived_path: string; reason?: string; }

const SOURCE_SECTION_HEADER: Record<SourceSection, string> = {
  blockers: '## Open blockers',
  decisions: '## Recent decisions',
};

export async function archiveToWiki(args: ArchiveToWikiArgs): Promise<ArchiveToWikiResult> {
  const brainDir = resolveBrainDir(args.brainDir);
  const knowledgeDir = resolveKnowledgeDir(args.knowledgeDir);

  // Path-traversal hardening (G-MCP-1, MCP Git CVE-2025-68143/4/5 pattern).
  try {
    validateSlug(args.slug);
  } catch (e) {
    if (e instanceof PathGuardError) {
      return { ok: false, archived_path: '', reason: `invalid slug: ${e.message}` };
    }
    throw e;
  }
  if (!ALLOWED_TARGET_CATEGORIES.has(args.targetCategory)) {
    return { ok: false, archived_path: '', reason: `invalid targetCategory: ${JSON.stringify(args.targetCategory)}` };
  }
  let projectFile: string;
  let wikiDir: string;
  try {
    projectFile = assertWithin(brainDir, 'projects', args.slug, 'PROJECT.md');
    wikiDir = assertWithin(knowledgeDir, 'wiki', args.targetCategory, args.slug);
  } catch (e) {
    if (e instanceof PathGuardError) {
      return { ok: false, archived_path: '', reason: `path traversal blocked: ${e.message}` };
    }
    throw e;
  }
  await fs.mkdir(wikiDir, { recursive: true });

  const content = await fs.readFile(projectFile, 'utf-8');
  const lines = content.split('\n');

  // Constrain the resolved-entry search to the requested section's window so
  // that a same-text entry in another section can't be archived by mistake.
  const sectionHeader = SOURCE_SECTION_HEADER[args.sourceSection];
  const startIdx = lines.findIndex(l => l.trim() === sectionHeader);
  if (startIdx < 0) {
    return { ok: false, archived_path: '', reason: `section ${sectionHeader} not found` };
  }
  let endIdx = lines.length;
  for (let i = startIdx + 1; i < lines.length; i++) {
    if (lines[i].startsWith('## ')) { endIdx = i; break; }
  }
  let matchIdx = -1;
  for (let i = startIdx + 1; i < endIdx; i++) {
    if (lines[i].includes(args.entryText) && lines[i].includes('[resolved]')) {
      matchIdx = i;
      break;
    }
  }
  if (matchIdx < 0) {
    return { ok: false, archived_path: '', reason: `no [resolved] entry matching text in ${sectionHeader}` };
  }
  const date = new Date().toISOString().slice(0, 10);
  const slugSafe = args.entryText.toLowerCase().replace(/[^a-z0-9]+/g, '-').slice(0, 40);
  const archivePath = join(wikiDir, `${date}-${slugSafe}.md`);
  await fs.writeFile(archivePath,
    `# ${args.entryText}\n\n**Archived:** ${date}\n**From:** projects/${args.slug}/PROJECT.md (section: ${args.sourceSection})\n**Status:** resolved\n`,
    'utf-8'
  );
  lines[matchIdx] = `  → wiki/${args.targetCategory}/${args.slug}/${date}-${slugSafe}.md`;
  await fs.writeFile(projectFile, lines.join('\n'), 'utf-8');
  return { ok: true, archived_path: archivePath };
}
