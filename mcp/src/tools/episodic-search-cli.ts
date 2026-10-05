import { serveEpisodicLines } from './episodic-search.js';
import { resolveBrainDir } from '../brain-paths.js';

// Fallback for the per-prompt "[Past sessions]" hint: persona-context.sh runs this CLI only when
// context-serve-cli is missing. It must serve exactly what context-serve-cli serves, so both call
// the one serveEpisodicLines step (no empty/machine user side, no echo of the current session, no
// duplicate openings, the same floor and pool) — or the fallback re-opens the noise R1 closed.
const query = process.argv[2] || '';
if (!query) { process.exit(0); }

const brainDir = resolveBrainDir();
// SP-1 parity: scope the per-prompt hint to the active project (suppress other-project
// noise, broaden only when this project has no in-scope hit). The slug is forwarded by
// persona-context.sh, mirroring the knowledge-search CLI.
const activeProject = process.env.SB_ACTIVE_SLUG?.trim() || undefined;
const sessionId = process.env.SB_SESSION_ID?.trim() || '';
const lines = await serveEpisodicLines(query, brainDir, { sessionId, activeProject });
for (const l of lines) console.log(l);
