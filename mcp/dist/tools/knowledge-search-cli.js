import { knowledgeSearch } from './knowledge-search.js';
const query = process.argv[2] || '';
if (!query) {
    process.exit(0);
}
const knowledgeDir = process.env.KNOWLEDGE_DIR || undefined;
// BM25 score floor — caller (persona-context.sh, session-load.sh) sets a
// minimum to suppress weak/irrelevant matches that surfaced as "noise".
// Default 0 = no filter (preserves prior behavior for callers that don't set it).
const minScore = parseFloat(process.env.KNOWLEDGE_MIN_SCORE || '0');
const result = await knowledgeSearch({ query, knowledgeDir });
const top = result.candidates
    .filter(c => c.score >= minScore)
    .slice(0, 2);
if (top.length === 0) {
    process.exit(0);
}
for (const c of top) {
    const slug = c.path.replace(/.*\//, '').replace(/\.md$/, '');
    const lines = c.first_lines.split('\n');
    const desc = lines.find(l => /^description:/.test(l))?.replace(/^description:\s*['"]?/, '').replace(/['"]?\s*$/, '') || '';
    console.log(`### [[${slug}]]${desc ? ' — ' + desc : ''}`);
}
//# sourceMappingURL=knowledge-search-cli.js.map