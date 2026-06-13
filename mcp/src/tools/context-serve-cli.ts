import { knowledgeSearch } from './knowledge-search.js';
import { episodicSearch } from './episodic-search.js';
import { join } from 'path';

// R6b (HOOK-7): the per-prompt UserPromptSubmit hook paid TWO node cold-starts
// (knowledge-search-cli + episodic-search-cli, ~0.5-1s each on a Pi 5, every
// prompt). This CLI answers both lookups in ONE process. Output contract:
// the wiki section (byte-identical to knowledge-search-cli's), then the
// separator line, then the episodic section (byte-identical to
// episodic-search-cli's). Both sections empty -> no output at all, exit 0.
// Each side fails OPEN to an empty section: per-prompt context is a hint,
// never worth blocking the prompt over.

const query = process.argv[2] || '';
if (!query) { process.exit(0); }

const SEP = '--8<--SB-EPISODIC--8<--';

// Same env resolution as knowledge-search-cli: SB_BRAIN_DIR first, matching
// the engine's accessCountsFile() and server.ts (R2). The episodic side gains
// SB_BRAIN_DIR support over the old CLI — strictly broader, same default.
const knowledgeDir = process.env.KNOWLEDGE_DIR || undefined;
const minScore = parseFloat(process.env.KNOWLEDGE_MIN_SCORE || '0');
const brainDir = process.env.SB_BRAIN_DIR || process.env.BRAIN_DIR
  || (process.env.HOME ? join(process.env.HOME, '.second-brain') : undefined);
const projectSlug = process.env.SB_ACTIVE_SLUG?.trim() || undefined;

const wikiLines: string[] = [];
try {
  const result = await knowledgeSearch({ query, knowledgeDir, brainDir, projectSlug });
  const top = result.candidates.filter(c => c.score >= minScore).slice(0, 2);
  for (const c of top) {
    const slug = c.path.replace(/.*\//, '').replace(/\.md$/, '');
    wikiLines.push(`### [[${slug}]]${c.description ? ' — ' + c.description : ''}`);
  }
} catch { /* fail-open: empty wiki section */ }

const epiLines: string[] = [];
try {
  if (!brainDir) throw new Error('no brain dir resolvable');
  const result = await episodicSearch(
    { query, limit: 2, mode: 'both', activeProject: projectSlug }, brainDir);
  const top = result.results.filter(r => r.similarity >= 0.15);
  const seen = new Set<string>();
  const deduped = top.filter(r => {
    const key = r.userSnippet.slice(0, 60);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  if (deduped.length > 0) {
    epiLines.push('[Past sessions — use episodic_search for full context]');
    for (const r of deduped) {
      const sim = Math.round(r.similarity * 100);
      epiLines.push(`- "${r.userSnippet.slice(0, 80)}..." (${r.project}, ${r.date}, ${sim}%)`);
    }
  }
} catch { /* fail-open: empty episodic section */ }

if (wikiLines.length === 0 && epiLines.length === 0) { process.exit(0); }
for (const l of wikiLines) console.log(l);
console.log(SEP);
for (const l of epiLines) console.log(l);
