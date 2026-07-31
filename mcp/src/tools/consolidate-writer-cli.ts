// consolidate-writer CLI — Stage B entry point, spawned by scripts/maintain-llm-drain.sh.
//
//   node consolidate-writer-cli.bundle.js --dream-dir <abs>
//
// Reads <dream-dir>/candidate-facts.json, applies validated facts to
// <dream-dir>/staging/wiki via the local BM25 reconcile, prints a JSON report to
// stdout. Exit 0 on success (including "no candidates"); non-zero with a stderr
// diagnostic on anything unrecoverable — the harness turns that into a terminal
// failed dream (fail-loud).
//
// Hermeticity: embeddings are FORCED OFF (deterministic BM25-only, no vector deps in
// the jail) and SB_BRAIN_DIR is pointed at a scratch dir inside the dream dir so
// knowledgeSearch's access-count telemetry cannot touch (or, under bwrap, crash on)
// the user's live BRAIN_DIR — the R2.2 hermeticity class.
import { promises as fs } from 'fs';
import { join } from 'path';
import { cleanEnvPath } from '../path-guard.js';

async function main(): Promise<number> {
  const idx = process.argv.indexOf('--dream-dir');
  const dreamDir = cleanEnvPath(idx > -1 ? process.argv[idx + 1] : '');
  if (!dreamDir) { process.stderr.write('usage: consolidate-writer-cli --dream-dir <abs>\n'); return 2; }

  process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = '1';
  process.env.SB_BRAIN_DIR = join(dreamDir, '.cw-scratch');
  await fs.mkdir(process.env.SB_BRAIN_DIR, { recursive: true });

  // Imports AFTER the env is pinned — knowledge-search resolves BRAIN_DIR per call,
  // but embeddings caches its disable check at module scope in some paths; be strict.
  const { validateCandidateFacts } = await import('./candidate-facts.js');
  const { applyCandidates } = await import('./consolidate-writer.js');
  const { knowledgeSearch } = await import('./knowledge-search.js');

  const stagingRoot = join(dreamDir, 'staging');
  try { await fs.access(join(stagingRoot, 'wiki')); }
  catch { process.stderr.write(`consolidate-writer: no staging wiki under ${stagingRoot}\n`); return 1; }

  let rawText: string;
  try { rawText = await fs.readFile(join(dreamDir, 'candidate-facts.json'), 'utf-8'); }
  catch {
    process.stdout.write(JSON.stringify({ added: [], updated: [], skipped: [], rejected: 0, note: 'no candidates' }) + '\n');
    return 0;
  }
  let raw: unknown;
  try { raw = JSON.parse(rawText); }
  catch (err: unknown) {
    process.stderr.write(`consolidate-writer: candidate-facts.json is not valid JSON: ${err instanceof Error ? err.message : String(err)}\n`);
    return 1;
  }
  const { facts, rejected } = validateCandidateFacts(raw);
  for (const r of rejected) process.stderr.write(`consolidate-writer: rejected fact[${r.index}]: ${r.reason}\n`);

  // Dream date from the dream id (drm_YYYYMMDDTHHMMSSZ) — deterministic; status.json
  // created_at is the fallback. No wall clock: reruns must be byte-identical.
  const base = dreamDir.replace(/[\\/]+$/, '').split(/[\\/]/).pop() || '';
  let date = '';
  const m = base.match(/^drm_(\d{4})(\d{2})(\d{2})T/);
  if (m) date = `${m[1]}-${m[2]}-${m[3]}`;
  if (!date) {
    try {
      const st = JSON.parse(await fs.readFile(join(dreamDir, 'status.json'), 'utf-8'));
      if (typeof st.created_at === 'string') date = st.created_at.slice(0, 10);
    } catch { /* fall through */ }
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    process.stderr.write(`consolidate-writer: cannot derive a dream date from '${base}' or status.json\n`);
    return 1;
  }

  const report = await applyCandidates(stagingRoot, facts, {
    dreamId: base,
    date,
    searchFn: async (query, scope) => {
      const r = await knowledgeSearch({ query, scope, knowledgeDir: stagingRoot });
      return r.candidates.map((c) => ({ path: c.path, score_norm: c.score_norm }));
    },
  });
  process.stdout.write(JSON.stringify({ ...report, rejected: rejected.length }) + '\n');
  return 0;
}

main().then(
  (code) => process.exit(code),
  (err: unknown) => {
    process.stderr.write(`consolidate-writer: ${err instanceof Error ? (err.stack || err.message) : String(err)}\n`);
    process.exit(1);
  }
);
