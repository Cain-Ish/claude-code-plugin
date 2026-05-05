import { promises as fs } from 'fs';
import { join, relative } from 'path';
import { parseDoc } from './knowledge-search.js';
import { knowledgeValidate, ValidationIssue } from './knowledge-validate.js';

export interface ReindexResult {
  pagesIndexed: number;
  categories: string[];
  indexPath: string;
  validation?: { issues: ValidationIssue[]; fixed: number };
}

export async function knowledgeReindex(knowledgeDir: string): Promise<ReindexResult> {
  const wikiRoot = join(knowledgeDir, 'wiki');
  const indexPath = join(wikiRoot, 'index.md');

  let dirs: string[];
  try {
    const entries = await fs.readdir(wikiRoot, { withFileTypes: true });
    dirs = entries.filter(d => d.isDirectory()).map(d => d.name).sort();
  } catch {
    return { pagesIndexed: 0, categories: [], indexPath };
  }

  const sections: string[] = ['# Knowledge Base Index', ''];
  let totalPages = 0;

  for (const dir of dirs) {
    const dirPath = join(wikiRoot, dir);
    const files = await collectMd(dirPath);
    if (files.length === 0) continue;

    const entries: { slug: string; title: string; description: string }[] = [];

    for (const filePath of files.sort()) {
      const slug = filePath.split('/').pop()!.replace(/\.md$/, '');
      try {
        const content = await fs.readFile(filePath, 'utf-8');
        const doc = parseDoc(content, filePath);
        const desc = doc.description || firstSentence(doc.body);
        entries.push({ slug, title: doc.title || slug, description: desc });
      } catch {
        entries.push({ slug, title: slug, description: '' });
      }
    }

    const label = dir.charAt(0).toUpperCase() + dir.slice(1);
    sections.push(`## ${label} (${entries.length} pages)`);
    for (const e of entries) {
      const desc = e.description ? ` — ${e.description}` : '';
      sections.push(`- [[${e.slug}]]${desc}`);
    }
    sections.push('');
    totalPages += entries.length;
  }

  if (totalPages === 0) {
    sections.push('*(no pages yet)*');
    sections.push('');
  }

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
  const text = body.replace(/^#.*\n/m, '').trim();
  const match = text.match(/^(.+?[.!?])\s/);
  return match ? match[1].slice(0, 120) : text.slice(0, 120);
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
