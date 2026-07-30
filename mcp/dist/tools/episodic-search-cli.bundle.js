// src/tools/episodic-search.ts
import { promises as fs3 } from "fs";

// src/tools/atomic-write.ts
import { promises as fs } from "fs";
async function atomicWriteJson(filePath, value) {
  const tmp = `${filePath}.tmp.${process.pid}`;
  try {
    await fs.writeFile(tmp, JSON.stringify(value));
    await fs.rename(tmp, filePath);
  } catch {
    try {
      await fs.unlink(tmp);
    } catch {
    }
  }
}

// src/tools/episodic-search.ts
import { join as join3, basename, relative, isAbsolute as isAbsolute2 } from "path";

// src/tools/embeddings.ts
import { promises as fs2 } from "fs";
import { join as join2 } from "path";

// src/brain-paths.ts
import { join, isAbsolute } from "path";
import { homedir } from "os";

// src/path-guard.ts
function cleanEnvPath(s) {
  return (s ?? "").replace(/[\r\n]/g, "");
}

// src/brain-paths.ts
function resolveBrainDir(override) {
  if (override) return override;
  return cleanEnvPath(process.env.SB_BRAIN_DIR || process.env.BRAIN_DIR) || join(homedir(), ".second-brain");
}

// src/tools/embeddings.ts
var EMBEDDING_DIM = 384;
var CACHE_FILE = ".embeddings-cache.json";
var MODEL_ID = "Xenova/all-MiniLM-L6-v2";
var DISABLE_ENV = "SECOND_BRAIN_DISABLE_EMBEDDINGS";
var pipelineInstance = null;
var lastLoadError = null;
function brainDirFromEnv() {
  return resolveBrainDir();
}
async function logLoadError(message, brainDir2) {
  if (!lastLoadError || lastLoadError.msg !== message) {
    lastLoadError = { msg: message, loggedTo: /* @__PURE__ */ new Set() };
  }
  if (lastLoadError.loggedTo.has(brainDir2)) return;
  lastLoadError.loggedTo.add(brainDir2);
  const entry = {
    timestamp: (/* @__PURE__ */ new Date()).toISOString().replace(/\.\d{3}Z$/, "Z"),
    script: "embeddings",
    message,
    exit_code: 0
  };
  try {
    await fs2.mkdir(brainDir2, { recursive: true });
    await fs2.appendFile(join2(brainDir2, "error-log.jsonl"), JSON.stringify(entry) + "\n");
  } catch {
  }
  try {
    process.stderr.write(`[embeddings] ${message}
`);
  } catch {
  }
}
async function getPipeline() {
  const brainDir2 = brainDirFromEnv();
  if (process.env[DISABLE_ENV] === "1") {
    try {
      process.stderr.write(`[embeddings] disabled via ${DISABLE_ENV}=1
`);
    } catch {
    }
    return null;
  }
  if (pipelineInstance) return pipelineInstance;
  try {
    const { pipeline } = await import("@huggingface/transformers");
    pipelineInstance = await pipeline("feature-extraction", MODEL_ID, { dtype: "fp32" });
    return pipelineInstance;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const hint = msg.includes("Cannot find package") ? " \u2014 run: bash $CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh" : "";
    await logLoadError(`transformers model load failed: ${msg}${hint}`, brainDir2);
    return null;
  }
}
function simpleHash(s) {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = (h << 5) - h + s.charCodeAt(i) | 0;
  }
  return h.toString(36);
}
async function loadCache(wikiRoot) {
  try {
    const data = await fs2.readFile(join2(wikiRoot, CACHE_FILE), "utf-8");
    const parsed = JSON.parse(data);
    if (parsed.model === MODEL_ID) return parsed;
  } catch {
  }
  return { model: MODEL_ID, entries: {} };
}
async function saveCache(wikiRoot, cache) {
  await atomicWriteJson(join2(wikiRoot, CACHE_FILE), cache);
}
async function embedTexts(texts, wikiRoot, paths) {
  const pipe = await getPipeline();
  if (!pipe) return null;
  const cache = await loadCache(wikiRoot);
  const results = [];
  let cacheUpdated = false;
  for (let i = 0; i < texts.length; i++) {
    const hash = simpleHash(texts[i]);
    const key = paths[i] || `query-${i}`;
    if (cache.entries[key]?.hash === hash) {
      results.push(cache.entries[key].vector);
      continue;
    }
    const output = await pipe(texts[i], { pooling: "mean", normalize: true });
    const vec = Array.from(output.data).slice(0, EMBEDDING_DIM);
    results.push(vec);
    if (paths[i]) {
      cache.entries[key] = { hash, vector: vec };
      cacheUpdated = true;
    }
  }
  if (cacheUpdated) await saveCache(wikiRoot, cache);
  return results;
}
function cosineSimilarity(a, b) {
  let dot = 0;
  for (let i = 0; i < a.length; i++) dot += a[i] * b[i];
  return dot;
}

// src/tools/episodic-search.ts
var INDEX_FILE = "episodic-index.json";
var DEFAULT_LIMIT = 10;
var MAX_LIMIT = 30;
async function loadIndex(brainDir2) {
  const indexPath = join3(brainDir2, INDEX_FILE);
  try {
    const data = await fs3.readFile(indexPath, "utf-8");
    return JSON.parse(data);
  } catch {
    return { model: "Xenova/all-MiniLM-L6-v2", indexed_files: {}, exchanges: [] };
  }
}
async function episodicSearch(args, brainDir2) {
  const index = await loadIndex(brainDir2);
  if (index.exchanges.length === 0) return { results: [] };
  const limit = Math.min(args.limit ?? DEFAULT_LIMIT, MAX_LIMIT);
  const query2 = args.query;
  if (Array.isArray(query2)) {
    return multiConceptSearch(query2, index, limit, args, brainDir2);
  }
  const mode = args.mode ?? "both";
  const candLimit = args.activeProject && !args.project ? Math.max(limit * 5, 25) : limit * 2;
  let vectorResults = [];
  let textResults = [];
  let degraded;
  if (mode === "vector" || mode === "both") {
    const v = await vectorSearch(query2, index, candLimit, args, brainDir2);
    vectorResults = v.hits;
    if (v.unavailable) degraded = mode === "both" ? "text-only" : "vector-unavailable";
  }
  if (mode === "text" || mode === "both") {
    textResults = textSearch(query2, index, candLimit, args);
  }
  const seen2 = /* @__PURE__ */ new Set();
  const merged = [];
  for (const r of vectorResults) {
    if (!seen2.has(r.id)) {
      seen2.add(r.id);
      merged.push(r);
    }
  }
  for (const r of textResults) {
    if (!seen2.has(r.id)) {
      seen2.add(r.id);
      merged.push(r);
    }
  }
  merged.sort((a, b) => b.similarity - a.similarity);
  return {
    results: scopeAndBroaden(merged, args).slice(0, limit).map((r) => ({
      sessionId: r.sessionId,
      project: r.project,
      date: r.date,
      userSnippet: r.userSnippet,
      assistantSnippet: r.assistantSnippet,
      similarity: Math.round(r.similarity * 1e3) / 1e3,
      archivePath: r.archivePath,
      lineStart: r.lineStart,
      lineEnd: r.lineEnd
    })),
    ...degraded ? { degraded } : {}
  };
}
async function vectorSearch(query2, index, limit, filters, brainDir2) {
  const filtered = applyFilters(index.exchanges, filters);
  const withEmbeddings = filtered.filter((e) => e.embedding.length > 0);
  if (withEmbeddings.length === 0) return { hits: [], unavailable: filtered.length > 0 };
  const queryEmbedding = await embedTexts(
    [query2],
    join3(brainDir2, "transcripts"),
    [""]
  );
  if (!queryEmbedding) return { hits: [], unavailable: true };
  const qVec = queryEmbedding[0];
  return {
    hits: withEmbeddings.map((e) => ({ ...e, similarity: cosineSimilarity(qVec, e.embedding) })).sort((a, b) => b.similarity - a.similarity).slice(0, limit),
    unavailable: false
  };
}
function textSearch(query2, index, limit, filters) {
  const filtered = applyFilters(index.exchanges, filters);
  const tokens = query2.toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length >= 2);
  if (tokens.length === 0) return [];
  const scored = [];
  for (const e of filtered) {
    const hay = (e.userSnippet + " " + e.assistantSnippet).toLowerCase();
    let allHit = true;
    let tf = 0;
    for (const t of tokens) {
      const occ = hay.split(t).length - 1;
      if (occ === 0) {
        allHit = false;
        break;
      }
      tf += occ;
    }
    if (allHit) {
      const similarity = 0.5 * (tf / (tf + tokens.length));
      scored.push({ ...e, similarity });
    }
  }
  scored.sort((a, b) => b.similarity - a.similarity);
  return scored.slice(0, limit);
}
async function multiConceptSearch(concepts, index, limit, filters, brainDir2) {
  const filtered = applyFilters(index.exchanges, filters);
  const withEmbeddings = filtered.filter((e) => e.embedding.length > 0);
  if (withEmbeddings.length === 0) {
    return { results: [], ...filtered.length > 0 ? { degraded: "vector-unavailable" } : {} };
  }
  const conceptEmbeddings = await embedTexts(
    concepts,
    join3(brainDir2, "transcripts"),
    concepts.map((_, i) => `concept-${i}`)
  );
  if (!conceptEmbeddings) return { results: [], degraded: "vector-unavailable" };
  const scored = withEmbeddings.map((e) => {
    const similarities = conceptEmbeddings.map((cv) => cosineSimilarity(cv, e.embedding));
    const minSim = Math.min(...similarities);
    const avgSim = similarities.reduce((a, b) => a + b, 0) / similarities.length;
    return { ...e, similarity: avgSim, minSimilarity: minSim };
  });
  const threshold = 0.2;
  const ranked = scopeAndBroaden(
    scored.filter((s) => s.minSimilarity >= threshold).sort((a, b) => b.similarity - a.similarity),
    filters
  );
  return {
    results: ranked.slice(0, limit).map((r) => ({
      sessionId: r.sessionId,
      project: r.project,
      date: r.date,
      userSnippet: r.userSnippet,
      assistantSnippet: r.assistantSnippet,
      similarity: Math.round(r.similarity * 1e3) / 1e3,
      archivePath: r.archivePath,
      lineStart: r.lineStart,
      lineEnd: r.lineEnd
    }))
  };
}
function applyFilters(exchanges, filters) {
  let result2 = exchanges;
  if (filters.project) {
    const p = filters.project.toLowerCase();
    result2 = result2.filter((e) => e.project.toLowerCase() === p);
  }
  if (filters.after) {
    result2 = result2.filter((e) => e.date >= filters.after);
  }
  if (filters.before) {
    result2 = result2.filter((e) => e.date <= filters.before);
  }
  return result2;
}
function scopeAndBroaden(ranked, args) {
  if (!args.activeProject || args.project) return ranked;
  const slug = args.activeProject.toLowerCase();
  const inScope = ranked.filter((r) => r.project.toLowerCase() === slug);
  const parsed = parseInt(process.env.SB_EPISODIC_SCOPE_MIN_HITS ?? "", 10);
  const minHits = Number.isFinite(parsed) && parsed >= 1 ? parsed : 1;
  return inScope.length >= minHits ? inScope : ranked;
}

// src/tools/episodic-search-cli.ts
var query = process.argv[2] || "";
if (!query) {
  process.exit(0);
}
var brainDir = resolveBrainDir();
var activeProject = process.env.SB_ACTIVE_SLUG?.trim() || void 0;
var result = await episodicSearch({ query, limit: 2, mode: "both", activeProject }, brainDir);
var top = result.results.filter((r) => r.similarity >= 0.15);
if (top.length === 0) {
  process.exit(0);
}
var seen = /* @__PURE__ */ new Set();
var deduped = top.filter((r) => {
  const key = r.userSnippet.slice(0, 60);
  if (seen.has(key)) return false;
  seen.add(key);
  return true;
});
if (deduped.length === 0) {
  process.exit(0);
}
console.log("[Past sessions \u2014 use episodic_search for full context]");
for (const r of deduped) {
  const sim = Math.round(r.similarity * 100);
  console.log(`- "${r.userSnippet.slice(0, 80)}..." (${r.project}, ${r.date}, ${sim}%)`);
}
