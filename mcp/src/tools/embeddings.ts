import { promises as fs } from 'fs';
import { join } from 'path';

const EMBEDDING_DIM = 384;
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
  return process.env.BRAIN_DIR || join(process.env.HOME ?? '', '.second-brain');
}

async function logLoadError(message: string, brainDir: string): Promise<void> {
  // Track which brain dirs have already received this error message to keep the log small,
  // but ensure each unique destination still gets one entry (matters for tests + multi-tenant).
  if (!lastLoadError || lastLoadError.msg !== message) {
    lastLoadError = { msg: message, loggedTo: new Set() };
  }
  if (lastLoadError.loggedTo.has(brainDir)) return;
  lastLoadError.loggedTo.add(brainDir);

  const entry = {
    timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    script: 'embeddings',
    message,
    exit_code: 0,
  };
  try {
    await fs.mkdir(brainDir, { recursive: true });
    await fs.appendFile(join(brainDir, 'error-log.jsonl'), JSON.stringify(entry) + '\n');
  } catch { /* logging is best-effort */ }
  try { process.stderr.write(`[embeddings] ${message}\n`); } catch { /* ignore */ }
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
  try {
    await fs.writeFile(join(wikiRoot, CACHE_FILE), JSON.stringify(cache));
  } catch { /* non-critical */ }
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

export function isAvailable(): boolean {
  return process.env[DISABLE_ENV] !== '1' && pipelineInstance !== null;
}
