import { promises as fs } from 'fs';
import { join } from 'path';
import { glob, escape } from 'glob';
import { parseDoc } from './knowledge-search.js';
import { capText, egressBudgetTokens, estimateTokens } from './egress-budget.js';
import { assertWithin, validateSlug, PathGuardError } from '../path-guard.js';
/** Collect the page's `##`/`###` headings, in order. */
function headings(body) {
    return body.split('\n').filter((l) => /^#{2,3}\s+\S/.test(l.trim())).map((l) => l.trim());
}
/** Extract the body of a `## Summary` section (until the next `## ` or EOF). */
function summarySection(body) {
    const lines = body.split('\n');
    const start = lines.findIndex((l) => /^##\s+summary\s*$/i.test(l.trim()));
    if (start === -1)
        return null;
    const out = [];
    for (let i = start + 1; i < lines.length; i++) {
        if (/^##\s+\S/.test(lines[i].trim()))
            break;
        out.push(lines[i]);
    }
    return out.join('\n').trim() || null;
}
export async function knowledgeFetch(args) {
    const tier = args.tier ?? 'gist';
    const knowledgeDir = args.knowledgeDir ?? join(process.env.HOME ?? '', 'knowledge');
    const wikiRoot = join(knowledgeDir, 'wiki');
    try {
        validateSlug(args.slug);
    }
    catch (e) {
        if (e instanceof PathGuardError) {
            return {
                slug: args.slug, path: null, tier,
                text: `Invalid slug: ${e.message}. Slugs must be 1-128 chars, [a-zA-Z0-9._-], no leading dot.`,
                tokens: 0, truncated: false, pointer: 'knowledge_search',
            };
        }
        throw e;
    }
    const matches = (await glob(`**/${escape(args.slug)}.md`, { cwd: wikiRoot, absolute: true }).catch(() => [])).sort();
    // Defense in depth: even though validateSlug rules out traversal syntax,
    // the wiki tree could contain symlinks pointing outside wikiRoot. Reject
    // any match whose realpath escapes.
    const filePath = matches.find((p) => {
        try {
            assertWithin(wikiRoot, p.startsWith(wikiRoot + '/') ? p.slice(wikiRoot.length + 1) : p);
            return true;
        }
        catch {
            return false;
        }
    }) ?? null;
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
    const gist = doc.description || doc.title || args.slug;
    let text;
    let truncated = false;
    if (tier === 'gist') {
        text = gist;
    }
    else if (tier === 'skeleton') {
        const hs = headings(doc.body);
        text = [gist, '', ...hs].join('\n').trim();
    }
    else if (tier === 'summary') {
        const summary = summarySection(doc.body);
        if (summary) {
            const capped = capText(summary, egressBudgetTokens(), fullPointer);
            text = capped.text;
            truncated = capped.truncated;
        }
        else {
            const hs = headings(doc.body);
            text = [gist, '', ...hs, '', '(no summary yet — use tier=full for the body)'].join('\n').trim();
        }
    }
    else {
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
//# sourceMappingURL=knowledge-fetch.js.map