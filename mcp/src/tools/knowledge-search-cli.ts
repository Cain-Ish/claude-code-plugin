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

// RELEVANCE GATE (the real one). `score` is NOT a relevance signal in hybrid mode — it is
// rank-derived RRF capped at 2/(60+1)*1.3 = 0.0426, and every query has a rank-1 document,
// so nonsense queries score as high as real ones (measured live: nonsense 0.0371 vs genuine
// 0.0282). The previous gate of 0.045 on `score` sat above that ceiling and made per-prompt
// wiki injection unconditionally dead whenever embeddings were active. Gate on the frozen
// `grounded` (DISCRIMINATIVE query terms in title/description/tags) instead. Measured on the
// live 372-page wiki, 6 genuine vs 6 nonsense queries: grounded>=2 gives 6/6 genuine and 0/6
// nonsense with NO score floor at all. grounded>=1 was not enough — it injected a page titled
// "orphaned-layered-armor-recipes" for "banana smoothie recipe", because one shared head-field
// term is not aboutness.
//
// SB_INJECT_MIN_RELEVANCE defaults to 0 ON PURPOSE. An absolute BM25 floor (35) also tested
// cleanly here, but BM25 is corpus-size dependent: on a small/new wiki df→N drives IDF→0 and
// every score collapses toward 0 however good the match, so a fixed floor would be unreachable
// there — the exact "gate above its own ceiling" bug this change exists to remove. The knob
// stays for tuning; it must not become a shipped constant again.
// Grounding is clamped to query_terms so a one- or two-word query stays satisfiable.
// Validated, NOT raw parseFloat/parseInt. A malformed override (`SB_INJECT_MIN_GROUNDED=true`,
// a stray quote, a trailing space) yields NaN; Math.min(NaN, x) is NaN and every `>= NaN`
// comparison is false, so the gate would match nothing, silently, for the whole session — the
// exact unsatisfiable-gate failure this file exists to fix, re-entered through an operator typo.
// A negative override is the mirror image: `grounded >= -1` is vacuously true and the precision
// gate disappears. Clamp both ends and fall back to the documented default.
const envNum = (name: string, def: number, lo: number, hi: number): number => {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return def;
  const v = Number(raw);
  return Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : def;
};
const minRelevance = envNum('SB_INJECT_MIN_RELEVANCE', 0, 0, Number.MAX_SAFE_INTEGER);
const minGrounded = envNum('SB_INJECT_MIN_GROUNDED', 2, 0, 64);

// SP-1: forward project context so the per-prompt persona injection is project-scoped.
// The calling hook (persona-context.sh / session-load.sh) sets SB_ACTIVE_SLUG.
// SB_BRAIN_DIR first, matching the engine's accessCountsFile() and server.ts —
// a split here would send scoping and access-counts to different trees (R2 review).
const brainDir = resolveBrainDir();
const projectSlug = process.env.SB_ACTIVE_SLUG || undefined;
const result = await knowledgeSearch({ query, brainDir, projectSlug });

const needGrounded = Math.min(minGrounded, result.candidates[0]?.query_terms ?? minGrounded);
const top = result.candidates
  .filter(c => c.score >= minScore && c.relevance >= minRelevance && c.grounded >= needGrounded)
  .slice(0, 2);
if (top.length === 0) { process.exit(0); }

for (const c of top) {
  const slug = c.path.replace(/^.*[\\/]/, '').replace(/\.md$/, '');
  console.log(`### [[${slug}]]${c.description ? ' — ' + c.description : ''}`);
}
