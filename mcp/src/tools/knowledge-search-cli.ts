import { knowledgeSearch } from './knowledge-search.js';
import { resolveBrainDir, resolveKnowledgeDir } from '../brain-paths.js';

const query = process.argv[2] || '';
if (!query) { process.exit(0); }

// Knowledge dir resolves canonically inside knowledgeSearch via brain-paths.ts
// (plugin option > KNOWLEDGE_DIR env > ~/knowledge, CRLF-cleaned) — a local
// env-read here used to invert that precedence (brain-paths source-scan lock).
// BM25 score floor — caller (persona-context.sh, session-load.sh) sets a
// minimum to suppress weak/irrelevant matches that surfaced as "noise".
// Default 0 = no filter (preserves prior behavior for callers that don't set it).
const minScore = parseFloat(process.env.KNOWLEDGE_MIN_SCORE || '0');

// SP-1: forward project context so the per-prompt persona injection is project-scoped.
// The calling hook (persona-context.sh / session-load.sh) sets SB_ACTIVE_SLUG.
// SB_BRAIN_DIR first, matching the engine's accessCountsFile() and server.ts —
// a split here would send scoping and access-counts to different trees (R2 review).
const brainDir = resolveBrainDir();
const projectSlug = process.env.SB_ACTIVE_SLUG || undefined;
const result = await knowledgeSearch({ query, brainDir, projectSlug });

const top = result.candidates
  .filter(c => c.score >= minScore)
  .slice(0, 2);
if (top.length === 0) { process.exit(0); }

for (const c of top) {
  const slug = c.path.replace(/^.*[\\/]/, '').replace(/\.md$/, '');
  console.log(`### [[${slug}]]${c.description ? ' — ' + c.description : ''}`);
}
