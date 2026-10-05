import { episodicSearch, servableEpisodes } from './episodic-search.js';
import { resolveBrainDir } from '../brain-paths.js';

// Fallback for the per-prompt "[Past sessions]" hint: persona-context.sh runs this CLI only when
// context-serve-cli is missing. It must serve exactly what context-serve-cli serves — the same
// servableEpisodes filter (no empty/machine user side, no echo of the current session, no
// duplicate openings), the same 0.15 floor and pool — or the fallback re-opens the noise R1 closed.
const query = process.argv[2] || '';
if (!query) { process.exit(0); }

const brainDir = resolveBrainDir();
// SP-1 parity: scope the per-prompt hint to the active project (suppress other-project
// noise, broaden only when this project has no in-scope hit). The slug is forwarded by
// persona-context.sh, mirroring the knowledge-search CLI.
const activeProject = process.env.SB_ACTIVE_SLUG?.trim() || undefined;
const sessionId = process.env.SB_SESSION_ID?.trim() || '';
const result = await episodicSearch({ query, limit: 10, mode: 'both', activeProject }, brainDir);

const served = servableEpisodes(result.results, { sessionId, minSimilarity: 0.15, max: 2 });
if (served.length === 0) { process.exit(0); }

console.log('[Past sessions — use episodic_search for full context]');
for (const r of served) {
  const sim = Math.round(r.similarity * 100);
  console.log(`- "${r.userSnippet.slice(0, 80)}..." (${r.project}, ${r.date}, ${sim}%)`);
}
