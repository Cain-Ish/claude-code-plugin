import { knowledgeSearch } from './knowledge-search.js';
const query = process.argv[2] || '';
if (!query) {
    process.exit(0);
}
const knowledgeDir = process.env.KNOWLEDGE_DIR || undefined;
const result = await knowledgeSearch({ query, knowledgeDir });
const top = result.candidates.slice(0, 2);
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