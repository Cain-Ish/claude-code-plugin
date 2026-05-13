import { episodicSearch } from './episodic-search.js';
import { join } from 'path';

const query = process.argv[2] || '';
if (!query) { process.exit(0); }

const brainDir = process.env.BRAIN_DIR || join(process.env.HOME ?? '', '.second-brain');
const result = await episodicSearch({ query, limit: 2, mode: 'vector' }, brainDir);

const top = result.results.filter(r => r.similarity >= 0.15);
if (top.length === 0) { process.exit(0); }

const seen = new Set<string>();
const deduped = top.filter(r => {
  const key = r.userSnippet.slice(0, 60);
  if (seen.has(key)) return false;
  seen.add(key);
  return true;
});
if (deduped.length === 0) { process.exit(0); }

console.log('[Past sessions — use episodic_search for full context]');
for (const r of deduped) {
  const sim = Math.round(r.similarity * 100);
  console.log(`- "${r.userSnippet.slice(0, 80)}..." (${r.project}, ${r.date}, ${sim}%)`);
}
