import { promises as fs } from 'fs';
import { join, relative } from 'path';
import { parseDoc } from './knowledge-search.js';
import { knowledgeValidate, ValidationIssue } from './knowledge-validate.js';
import { projectGraphToPages } from './graph-project.js';
import { buildProjectMocs, MocInput } from './project-moc.js';
import { stripAiBlock } from './ai-block.js';

export interface ReindexResult {
  pagesIndexed: number;
  categories: string[];
  indexPath: string;
  validation?: { issues: ValidationIssue[]; fixed: number };
}

export async function knowledgeReindex(knowledgeDir: string): Promise<ReindexResult> {
  // Project the relationship graph onto pages first, so the index + validation
  // see current related: links. No-op when ~/knowledge/graph/edges.jsonl absent.
  try { await projectGraphToPages(knowledgeDir); } catch { /* projection is best-effort */ }

  const wikiRoot = join(knowledgeDir, 'wiki');
  const indexPath = join(wikiRoot, 'index.md');

  let dirs: string[];
  try {
    const entries = await fs.readdir(wikiRoot, { withFileTypes: true });
    dirs = entries.filter(d => d.isDirectory()).map(d => d.name).sort();
  } catch {
    return { pagesIndexed: 0, categories: [], indexPath };
  }

  const allPages: MocInput[] = [];
  const categoryRows: string[] = [];
  let totalPages = 0;

  for (const dir of dirs) {
    if (dir === 'projects') continue; // generated MOCs — projected below, not indexed as content
    const dirPath = join(wikiRoot, dir);
    const files = await collectMd(dirPath);
    if (files.length === 0) continue;

    const entries: { slug: string; description: string }[] = [];
    for (const filePath of files.sort()) {
      const slug = filePath.split('/').pop()!.replace(/\.md$/, '');
      try {
        const content = await fs.readFile(filePath, 'utf-8');
        const doc = parseDoc(content, filePath);
        const desc = doc.description || firstSentence(doc.body);
        entries.push({ slug, description: desc });
        allPages.push({ slug, type: dir, project: doc.project, title: doc.title || slug, description: desc });
      } catch {
        entries.push({ slug, description: '' });
        allPages.push({ slug, type: dir, project: '', title: slug, description: '' });
      }
    }
    totalPages += entries.length;
    if (dir === 'themes') continue; // theme MOCs are listed under Maps of Content, not Categories
    const label = dir.charAt(0).toUpperCase() + dir.slice(1);
    categoryRows.push(`- **${label}** (${entries.length}): ${entries.map(e => e.slug).join(', ')}`);
  }

  // Project MOCs — deterministic projection of the project: facet (>= minMembers). Written
  // BEFORE the index so the projects/ dir is listed, and before validation so they're checked.
  const rawMin = Number(process.env.SB_MOC_MIN_MEMBERS);
  const minMembers = Number.isFinite(rawMin) && rawMin >= 1 ? rawMin : 3; // NaN/0/negative ⇒ default 3
  const mocs = process.env.SB_KB_MOC === 'off' ? new Map<string, string>() : buildProjectMocs(allPages, { minMembers });
  const projDir = join(wikiRoot, 'projects');
  if (mocs.size > 0) await fs.mkdir(projDir, { recursive: true });
  // Prune stale MOCs: a project that dropped below the threshold (or was renamed/removed)
  // must not leave an orphaned MOC. This keeps the projection a pure function of CURRENT
  // input — output no longer depends on prior on-disk state.
  for (const existing of await mocSlugs(projDir)) {
    if (!mocs.has(existing)) { try { await fs.unlink(join(projDir, `${existing}.md`)); } catch { /* gone */ } }
  }
  for (const [proj, region] of mocs) {
    // QUOTE both title and description (0.28.3): `proj` is an author-controlled
    // project: facet value. An unquoted value containing a colon (or other YAML
    // meta char) makes the generated MOC invalid YAML — the tolerant regex
    // readers mask it but the validator's yaml.load detector rejects it (0.26.0
    // fixed description; title was still raw). JSON.stringify yields a valid
    // double-quoted scalar (YAML accepts JSON-style quoting + escapes).
    const header = ['---', `title: ${JSON.stringify(proj)}`, 'type: projects', 'generated: true', 'graph: exclude',
      `description: ${JSON.stringify(`Map of Content for the ${proj} project (auto-generated).`)}`, '---', ''].join('\n');
    await fs.writeFile(join(projDir, `${proj}.md`), header + region + '\n', 'utf-8');
  }

  // Two-tier, de-hubbed index: Home -> MOC links + per-type counts (plain-text slug rows, so a
  // markdown graph viewer never treats index.md as a 100-edge hub). graph: exclude marks it out.
  const sections: string[] = [
    '---', 'title: Knowledge Base Index', 'type: index', 'graph: exclude', '---', '',
    '# Knowledge Base Index', '',
  ];
  const mocLinks: string[] = [];
  for (const slug of await mocSlugs(projDir)) mocLinks.push(`- [[projects/${slug}]]`);
  for (const slug of await mocSlugs(join(wikiRoot, 'themes'))) mocLinks.push(`- [[themes/${slug}]]`);
  if (mocLinks.length) sections.push('## Maps of Content', '', ...mocLinks, '');
  if (categoryRows.length) sections.push('## Categories', '', ...categoryRows, '');
  if (totalPages === 0 && mocLinks.length === 0) sections.push('*(no pages yet)*', '');
  sections.push(`<!-- generated: ${new Date().toISOString()} -->`);

  await fs.writeFile(indexPath, sections.join('\n'), 'utf-8');

  const validation = await knowledgeValidate(knowledgeDir, { autofix: true });

  return {
    pagesIndexed: totalPages,
    categories: dirs,
    indexPath,
    validation: validation.issues.length > 0 || validation.fixed > 0
      ? { issues: validation.issues, fixed: validation.fixed }
      : undefined,
  };
}

function firstSentence(body: string): string {
  const text = stripAiBlock(body)                          // drop the authored ai-block
    .replace(/<!-- graph:begin[\s\S]*?graph:end -->/g, '') // drop the generated projection block
    .replace(/^#.*\n/m, '')
    .trim();
  const match = text.match(/^(.+?[.!?])\s/);
  return match ? match[1].slice(0, 120) : text.slice(0, 120);
}

async function mocSlugs(dir: string): Promise<string[]> {
  try {
    return (await fs.readdir(dir))
      .filter(f => f.endsWith('.md') && f !== 'index.md')
      .map(f => f.replace(/\.md$/, ''))
      .sort();
  } catch { return []; }
}

async function collectMd(dir: string, acc: string[] = []): Promise<string[]> {
  try {
    for (const e of await fs.readdir(dir, { withFileTypes: true })) {
      const p = join(dir, e.name);
      if (e.isDirectory()) await collectMd(p, acc);
      else if (e.isFile() && e.name.endsWith('.md') && e.name !== 'index.md') acc.push(p);
    }
  } catch { /* dir vanished */ }
  return acc;
}
