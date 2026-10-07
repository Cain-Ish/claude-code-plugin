import { knowledgeSearch, injectableWiki, reportInjectPrecision, injectedHitLine } from './knowledge-search.js';
import { serveEpisodicLines } from './episodic-search.js';
import { resolveBrainDir, resolveKnowledgeDir } from '../brain-paths.js';

// R6b (HOOK-7): the per-prompt UserPromptSubmit hook paid TWO node cold-starts
// (knowledge-search-cli + episodic-search-cli, ~0.5-1s each on a Pi 5, every
// prompt). This CLI answers both lookups in ONE process. Output contract:
// the wiki section (same line format as knowledge-search-cli's; identical
// output for non-stub in-project pages), then the separator line, then the
// episodic section (same line format as episodic-search-cli's). Both sections
// empty -> no output at all, exit 0.
// Each side fails OPEN to an empty section: per-prompt context is a hint,
// never worth blocking the prompt over.

const query = process.argv[2] || '';
if (!query) { process.exit(0); }

const SEP = '--8<--SB-EPISODIC--8<--';

// Same env resolution as knowledge-search-cli: SB_BRAIN_DIR first, matching
// the engine's accessCountsFile() and server.ts (R2). The episodic side
// honors SB_BRAIN_DIR too.
const knowledgeDir = resolveKnowledgeDir();
const minScore = parseFloat(process.env.KNOWLEDGE_MIN_SCORE || '0');
// The PER-PROMPT injection gate. Same knobs as knowledge-search-cli.ts, deliberately NOT the
// same gate (R1#4, 2026-10): the recall harness (wiki-recall-check.sh) and the FORGET probe read
// knowledge-search-cli, so its gate stays as it was. This one, via injectableWiki():
//   - never injects a stub (`Auto-created stub` description, auto-extracted skeleton, or a
//     stripped body under 100 chars);
//   - clamps the grounding need to the DISCRIMINATIVE term count (floor 1), so one real term
//     among filler can still inject, and an all-filler query injects nothing;
//   - asks a cross-project page (project: set and != SB_ACTIVE_SLUG, case-insensitive) for one
//     more grounded term, clamped to the same count so it stays satisfiable.
// `score` (RRF, ceiling 0.0426) cannot gate relevance; `relevance` (frozen BM25) + `grounded`
// (query terms in title/description/tags) can. Full rationale in knowledge-search-cli.ts.
// retrieval-guards.test.ts locks the arithmetic against the default below.
// SB_INJECT_PRECISION=off (read once by the engine, not here) makes injectableWiki the 0.54.1
// filter again; see knowledge-search.ts. The hook discards this CLI's stderr, so the switch is
// reported below (reportInjectPrecision): an unrecognised value leaves an error-log.jsonl row, off
// a gate=inject-precision TRACE row in audit-log.jsonl, the default writes nothing.
// Validated, not raw parseFloat/parseInt — a malformed override yields NaN, every `>= NaN` is
// false, and the gate silently matches nothing for the whole session (the unsatisfiable-gate
// class again); a negative one makes it vacuously true. Same guard as knowledge-search-cli.ts.
const envNum = (name: string, def: number, lo: number, hi: number): number => {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return def;
  const v = Number(raw);
  return Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : def;
};
const minRelevance = envNum('SB_INJECT_MIN_RELEVANCE', 0, 0, Number.MAX_SAFE_INTEGER);
const minGrounded = envNum('SB_INJECT_MIN_GROUNDED', 2, 0, 64);
const brainDir = resolveBrainDir();
const projectSlug = process.env.SB_ACTIVE_SLUG?.trim() || undefined;
await reportInjectPrecision(brainDir, 'context-serve-cli');

const wikiLines: string[] = [];
try {
  const result = await knowledgeSearch({ query, knowledgeDir, brainDir, projectSlug });
  const top = injectableWiki(result.candidates, { minScore, minRelevance, minGrounded }).slice(0, 2);
  // Same renderer as knowledge-search-cli (the wiki-section parity test locks it): folded fields,
  // a local doc as a Read line, '' for a candidate that must not be printed.
  for (const c of top) {
    const line = injectedHitLine(c);
    if (line) wikiLines.push(line);
  }
} catch { /* fail-open: empty wiki section */ }

// The hook passes the live session id: its own exchanges are already in context, so serving
// them back is an echo (9 of 76 graded snippet lines were the user's own earlier prompt).
const sessionId = process.env.SB_SESSION_ID?.trim() || '';
let epiLines: string[] = [];
try {
  if (!brainDir) throw new Error('no brain dir resolvable');
  // serveEpisodicLines is the one serve step shared with the fallback episodic-search-cli: the
  // pool, the hardcoded 0.15 floor (no knob, R1#3; it filters vector hits only — a text hit
  // scores >= 0.25) and the servableEpisodes filter live there.
  epiLines = await serveEpisodicLines(query, brainDir, { sessionId, activeProject: projectSlug });
} catch { /* fail-open: empty episodic section */ }

if (wikiLines.length === 0 && epiLines.length === 0) { process.exit(0); }
for (const l of wikiLines) console.log(l);
console.log(SEP);
for (const l of epiLines) console.log(l);
