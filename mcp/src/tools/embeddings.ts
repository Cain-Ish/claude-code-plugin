import { promises as fs } from 'fs';
import { join } from 'path';
import { resolveBrainDir } from '../brain-paths.js';
import { atomicWriteJson } from './atomic-write.js';

export const EMBEDDING_DIM = 384;
const CACHE_FILE = '.embeddings-cache.json';
const MODEL_ID = 'Xenova/all-MiniLM-L6-v2';
const DISABLE_ENV = 'SECOND_BRAIN_DISABLE_EMBEDDINGS';

interface EmbeddingCache {
  model: string;
  entries: Record<string, { hash: string; vector: number[] }>;
}

let pipelineInstance: any = null;
let lastLoadError: { msg: string; loggedTo: Set<string> } | null = null;

function brainDirFromEnv(): string {
  return resolveBrainDir();
}

async function logLoadError(message: string, brainDir: string): Promise<void> {
  // Track which brain dirs have already received this error message to keep the log small,
  // but ensure each unique destination still gets one entry (matters for tests + multi-tenant).
  if (!lastLoadError || lastLoadError.msg !== message) {
    lastLoadError = { msg: message, loggedTo: new Set() };
  }
  if (lastLoadError.loggedTo.has(brainDir)) return;
  lastLoadError.loggedTo.add(brainDir);
  await appendErrorLog(brainDir, 'embeddings', message, 0);
}

/** The TS twin of lib.sh's sb_log_error: one `{timestamp, script, message, exit_code}` row in
 *  `<brainDir>/error-log.jsonl`, echoed to stderr. If the row cannot be written, the stderr line
 *  says so: the failure is never silent, and logging never throws into its caller. */
export async function appendErrorLog(brainDir: string, script: string, message: string, exitCode = 1): Promise<void> {
  const entry = {
    timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    script,
    message,
    exit_code: exitCode,
  };
  let note = '';
  try {
    await fs.mkdir(brainDir, { recursive: true });
    await fs.appendFile(join(brainDir, 'error-log.jsonl'), JSON.stringify(entry) + '\n');
  } catch (e) {
    note = ` (error-log.jsonl write failed: ${e instanceof Error ? e.message : String(e)})`;
  }
  try { process.stderr.write(`[${script}] ${message}${note}\n`); } catch { /* stderr gone: nothing left to tell */ }
}

/** The TS twin of sb_log_error's REROUTED row: a `gate=*` message at exit_code 0 is a TRACE, not an
 *  error, so it goes to `<brainDir>/audit-log.jsonl` in the same `{timestamp, script, message,
 *  exit_code}` shape, as one compact line in a single append. Silent on success (a TRACE is not
 *  news); a failed write is echoed to stderr and never thrown. No rotation here: the next bash
 *  sb_log_error caller rotates the file (sb_rotate_audit_log), as with persona-context's _mt_log. */
export async function appendGateTrace(brainDir: string, script: string, message: string): Promise<void> {
  const entry = {
    timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    script,
    message,
    exit_code: 0,
  };
  try {
    await fs.mkdir(brainDir, { recursive: true });
    await fs.appendFile(join(brainDir, 'audit-log.jsonl'), JSON.stringify(entry) + '\n');
  } catch (e) {
    const why = e instanceof Error ? e.message : String(e);
    try { process.stderr.write(`[${script}] ${message} (audit-log.jsonl write failed: ${why})\n`); } catch { /* stderr gone */ }
  }
}

/** The explicit opt-out: an acknowledged choice, not a degradation, so callers stay quiet about it. */
export function embeddingsOptedOut(): boolean {
  return process.env[DISABLE_ENV] === '1';
}

async function getPipeline(): Promise<any> {
  const brainDir = brainDirFromEnv();
  if (process.env[DISABLE_ENV] === '1') {
    // User explicitly disabled embeddings — informational, not an error.
    // Previously this called logLoadError which appended to error-log.jsonl
    // every process startup (in-memory dedup couldn't cross processes), so
    // vitest runs alone dropped ~500 noise rows. stderr is the right channel
    // for an opt-in disable acknowledgement.
    try { process.stderr.write(`[embeddings] disabled via ${DISABLE_ENV}=1\n`); } catch { /* ignore */ }
    return null;
  }
  if (pipelineInstance) return pipelineInstance;
  try {
    const { pipeline } = await import('@huggingface/transformers');
    pipelineInstance = await pipeline('feature-extraction', MODEL_ID, { dtype: 'fp32' });
    return pipelineInstance;
  } catch (e) {
    const msg = (e instanceof Error ? e.message : String(e));
    const hint = msg.includes('Cannot find package')
      ? ' — run: bash $CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh'
      : '';
    await logLoadError(`transformers model load failed: ${msg}${hint}`, brainDir);
    return null;
  }
}

function simpleHash(s: string): string {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = ((h << 5) - h + s.charCodeAt(i)) | 0;
  }
  return h.toString(36);
}

async function loadCache(wikiRoot: string): Promise<EmbeddingCache> {
  try {
    const data = await fs.readFile(join(wikiRoot, CACHE_FILE), 'utf-8');
    const parsed = JSON.parse(data);
    if (parsed.model === MODEL_ID) return parsed;
  } catch { /* cache miss */ }
  return { model: MODEL_ID, entries: {} };
}

async function saveCache(wikiRoot: string, cache: EmbeddingCache): Promise<void> {
  // tmp+rename via the house helper: this cache is rewritten on every search that
  // embeds a new/changed page, so a plain writeFile races any concurrent reader
  // (or a second writer) into a torn file → silent full re-embed.
  await atomicWriteJson(join(wikiRoot, CACHE_FILE), cache);
}

export async function embedTexts(texts: string[], wikiRoot: string, paths: string[]): Promise<number[][] | null> {
  const pipe = await getPipeline();
  if (!pipe) return null;

  const cache = await loadCache(wikiRoot);
  const results: number[][] = [];
  let cacheUpdated = false;

  for (let i = 0; i < texts.length; i++) {
    const hash = simpleHash(texts[i]);
    const key = paths[i] || `query-${i}`;

    if (cache.entries[key]?.hash === hash) {
      results.push(cache.entries[key].vector);
      continue;
    }

    const output = await pipe(texts[i], { pooling: 'mean', normalize: true });
    const vec = Array.from(output.data as Float32Array).slice(0, EMBEDDING_DIM);
    results.push(vec);

    if (paths[i]) {
      cache.entries[key] = { hash, vector: vec };
      cacheUpdated = true;
    }
  }

  if (cacheUpdated) await saveCache(wikiRoot, cache);
  return results;
}

export function cosineSimilarity(a: number[], b: number[]): number {
  let dot = 0;
  for (let i = 0; i < a.length; i++) dot += a[i] * b[i];
  return dot; // vectors are already normalized
}
