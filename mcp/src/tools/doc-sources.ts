import { createHash } from 'crypto';

export function hashContent(content: string): string {
  return createHash('sha256').update(content).digest('hex');
}

/** Gist = first H1 / frontmatter title / first non-empty line. Deterministic, no LLM. */
export function extractGist(content: string): string {
  const fm = content.match(/^---\n([\s\S]*?)\n---/);
  const body = fm ? content.slice(fm[0].length) : content;
  const h1 = body.match(/^#\s+(.+)$/m);
  if (h1) return h1[1].trim();
  if (fm) {
    const t = fm[1].match(/^title:\s*["']?(.+?)["']?\s*$/m);
    if (t) return t[1].trim();
  }
  const first = body.split('\n').map((l) => l.trim()).find((l) => l.length > 0);
  return first ?? '';
}

/** H2/H3 headings, in order (excludes the H1 title). */
export function extractHeadings(content: string): string[] {
  return content.split('\n').map((l) => l.trim()).filter((l) => /^#{2,3}\s+\S/.test(l));
}
