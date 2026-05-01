import { promises as fs } from 'fs';
import { join } from 'path';
const SNIPPET_CHARS = 200;
const TOP_K = 5;
const FIRST_N_LINES = 10;
export async function knowledgeSearch(args) {
    const knowledgeDir = args.knowledgeDir ?? join(process.env.HOME ?? '', 'knowledge');
    const wikiRoot = join(knowledgeDir, 'wiki');
    const scopeDirs = args.scope
        ? [join(wikiRoot, args.scope)]
        : ['concepts', 'issues', 'entities', 'learnings', 'decisions'].map(s => join(wikiRoot, s));
    const queryTokens = tokenize(args.query);
    const candidates = [];
    for (const dir of scopeDirs) {
        let entries = [];
        try {
            entries = await collectMarkdown(dir);
        }
        catch {
            continue;
        }
        for (const path of entries) {
            const head = await firstLines(path, FIRST_N_LINES);
            const score = scoreTokens(queryTokens, head + ' ' + path);
            if (score > 0)
                candidates.push({ path, score, first_lines: head.slice(0, SNIPPET_CHARS) });
        }
    }
    candidates.sort((a, b) => b.score - a.score);
    return { candidates: candidates.slice(0, TOP_K) };
}
function tokenize(s) { return s.toLowerCase().match(/[a-z0-9]+/g) ?? []; }
function scoreTokens(query, text) {
    const t = new Set(tokenize(text));
    return query.filter(q => t.has(q)).length;
}
async function collectMarkdown(dir, acc = []) {
    for (const e of await fs.readdir(dir, { withFileTypes: true })) {
        const p = join(dir, e.name);
        if (e.isDirectory())
            await collectMarkdown(p, acc);
        else if (e.isFile() && e.name.endsWith('.md'))
            acc.push(p.split(/[\\/]/).join('/'));
    }
    return acc;
}
async function firstLines(path, n) {
    const content = await fs.readFile(path, 'utf-8');
    return content.split('\n').slice(0, n).join('\n');
}
//# sourceMappingURL=knowledge-search.js.map