import { promises as fs } from 'fs';
import { join } from 'path';
import { assertWithin, validateSlug, PathGuardError } from '../path-guard.js';
import { resolveBrainDir, resolveKnowledgeDir } from '../brain-paths.js';
import { withFileLock } from './hot-file-lock.js';
import { writeFileAtomic } from './atomic-write.js';

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
  // M6: "" is a substring of every line, so it archived whatever [resolved] entry came first.
  if (!args.entryText.trim()) {
    return { ok: false, archived_path: '', reason: 'empty entryText' };
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
  // E3: the PROJECT.md read-modify-write holds the shared .PROJECT.md.lock (the merge holds it too)
  // and replaces the file by temp + rename.
  return withFileLock(projectFile, reason => ({ ok: false, archived_path: '', reason }),
    () => archiveLocked(args, projectFile, wikiDir));
}

async function archiveLocked(args: ArchiveToWikiArgs, projectFile: string, wikiDir: string): Promise<ArchiveToWikiResult> {
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
  const ts = new Date().toISOString();
  const date = ts.slice(0, 10);
  const slugSafe = args.entryText.toLowerCase().replace(/[^a-z0-9]+/g, '-').slice(0, 40);
  // Full frontmatter incl. the project: facet — without it every graduated entry is
  // tier-4 "global" to project-scoped search and invisible to the project MOC.
  // JSON.stringify = YAML-safe double-quoted scalar (entryText is user prose).
  const frontmatter = [
    '---',
    `title: ${JSON.stringify(args.entryText.slice(0, 120))}`,
    `type: ${args.targetCategory}`,
    `description: ${JSON.stringify(args.entryText.slice(0, 200))}`,
    `created: ${ts}`,
    `updated: ${ts}`,
    // Quoted like every other writer of this facet (parseDoc strips quotes) — safe
    // today because validateSlug ran, but the quoting must not depend on that.
    `project: ${JSON.stringify(args.slug)}`,
    '---',
    '',
  ].join('\n');
  // M6: never overwrite an earlier archive. Non-ASCII text slugs alike ("-"), so a same-day second
  // archive replaced the first page; create exclusively and take the next free -N suffix instead.
  const page = `${frontmatter}# ${args.entryText}\n\n**Archived:** ${date}\n**From:** projects/${args.slug}/PROJECT.md (section: ${args.sourceSection})\n**Status:** resolved\n`;
  let archiveName = '';
  for (let n = 1; !archiveName; n++) {
    const name = `${date}-${slugSafe}${n > 1 ? `-${n}` : ''}.md`;
    try {
      await fs.writeFile(join(wikiDir, name), page, { encoding: 'utf-8', flag: 'wx' });
      archiveName = name;
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== 'EEXIST' || n >= 100) throw e;
    }
  }
  const archivePath = join(wikiDir, archiveName);
  lines[matchIdx] = `  → wiki/${args.targetCategory}/${args.slug}/${archiveName}`;
  // The page is already on disk: a failed PROJECT.md replace must not leave an orphan that a retry duplicates as -2.md.
  try { await writeFileAtomic(projectFile, lines.join('\n')); }
  catch (e) { await fs.rm(archivePath, { force: true }).catch(() => {}); throw e; }
  return { ok: true, archived_path: archivePath };
}
