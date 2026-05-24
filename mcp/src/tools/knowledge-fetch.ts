import { promises as fs } from 'fs';
import { join } from 'path';
import { glob } from 'glob';
import { parseDoc } from './knowledge-search.js';
import { capText, egressBudgetTokens, estimateTokens } from './egress-budget.js';

export type Tier = 'gist' | 'skeleton' | 'summary' | 'full';

export interface KnowledgeFetchArgs {
  slug: string;
  tier?: Tier;
  knowledgeDir?: string;
}

export interface KnowledgeFetchResult {
  slug: string;
  path: string | null;
  tier: Tier;
  text: string;
  tokens: number;
  truncated: boolean;
  pointer: string;
}

/** Collect the page's `##`/`###` headings, in order. */
function headings(body: string): string[] {
  return body.split('\n').filter((l) => /^#{2,3}\s+\S/.test(l.trim())).map((l) => l.trim());
}

/** Extract the body of a `## Summary` section (until the next `## ` or EOF). */
function summarySection(body: string): string | null {
  const lines = body.split('\n');
  const start = lines.findIndex((l) => /^##\s+summary\s*$/i.test(l.trim()));
  if (start === -1) return null;
  const out: string[] = [];
  for (let i = start + 1; i < lines.length; i++) {
    if (/^##\s+\S/.test(lines[i].trim())) break;
    out.push(lines[i]);
  }
  return out.join('\n').trim() || null;
}

export async function knowledgeFetch(args: KnowledgeFetchArgs): Promise<KnowledgeFetchResult> {
  const tier: Tier = args.tier ?? 'gist';
  const knowledgeDir = args.knowledgeDir ?? join(process.env.HOME ?? '', 'knowledge');
  const wikiRoot = join(knowledgeDir, 'wiki');

  const matches = await glob(`**/${args.slug}.md`, { cwd: wikiRoot, absolute: true }).catch(() => [] as string[]);
  const filePath = matches[0] ?? null;
  if (!filePath) {
    return {
      slug: args.slug,
      path: null,
      tier,
      text: `Page not found for slug "${args.slug}". Try knowledge_search to find the right slug.`,
      tokens: 0,
      truncated: false,
      pointer: 'knowledge_search',
    };
  }

  const raw = await fs.readFile(filePath, 'utf-8');
  const doc = parseDoc(raw, filePath);
  const fullPointer = `Read ${filePath} for the full page`;
  const gist = doc.description || (doc.title ? doc.title : args.slug);

  let text: string;
  let truncated = false;

  if (tier === 'gist') {
    text = gist;
  } else if (tier === 'skeleton') {
    const hs = headings(doc.body);
    text = [gist, '', ...hs].join('\n').trim();
  } else if (tier === 'summary') {
    const summary = summarySection(doc.body);
    if (summary) {
      const capped = capText(summary, egressBudgetTokens(), fullPointer);
      text = capped.text;
      truncated = capped.truncated;
    } else {
      const hs = headings(doc.body);
      text = [gist, '', ...hs, '', '(no summary yet — use tier=full for the body)'].join('\n').trim();
    }
  } else {
    const capped = capText(doc.body.trim(), egressBudgetTokens(), fullPointer);
    text = capped.text;
    truncated = capped.truncated;
  }

  return {
    slug: args.slug,
    path: filePath,
    tier,
    text,
    tokens: estimateTokens(text),
    truncated,
    pointer: tier === 'full' ? fullPointer : `knowledge_fetch("${args.slug}", "full")`,
  };
}
