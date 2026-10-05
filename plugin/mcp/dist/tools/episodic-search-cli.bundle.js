// src/tools/episodic-search.ts
import { promises as fs3 } from "fs";

// src/tools/atomic-write.ts
import { promises as fs } from "fs";
async function atomicWriteJson(filePath, value) {
  const tmp = `${filePath}.tmp.${process.pid}`;
  try {
    await fs.writeFile(tmp, JSON.stringify(value));
    await fs.rename(tmp, filePath);
  } catch (err) {
    console.error(
      `atomicWriteJson: FAILED to write ${filePath}: ${err instanceof Error ? err.message : String(err)}`
    );
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
function normForCompare(p) {
  let s = cleanEnvPath(p).trim().split(String.fromCharCode(92)).join("/");
  const m = s.match(/^[/]([A-Za-z])([/].*)?$/);
  if (m) s = `${m[1]}:${m[2] ?? "/"}`;
  s = s.replace(/[/]+$/, "");
  return /^[A-Za-z]:/.test(s) ? s.toLowerCase() : s;
}
function suiteGuard(kind, resolved) {
  const real = cleanEnvPath(process.env.SB_SUITE_REAL_HOME_PATH);
  if (!real.trim()) return resolved;
  const forbidden = normForCompare(`${real}/${kind === "brain" ? ".second-brain" : "knowledge"}`);
  if (normForCompare(resolved) === forbidden) {
    throw new Error(
      `suite guard: ${kind} dir resolved to the REAL ${resolved} while SB_SUITE_REAL_HOME_PATH is set (a test leaked past the run-all sandbox; set BRAIN_DIR/KNOWLEDGE_DIR to a temp dir in that test)`
    );
  }
  return resolved;
}
function resolveBrainDir(override) {
  if (override) return suiteGuard("brain", override);
  return suiteGuard(
    "brain",
    cleanEnvPath(process.env.SB_BRAIN_DIR || process.env.BRAIN_DIR) || join(homedir(), ".second-brain")
  );
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
  await appendErrorLog(brainDir2, "embeddings", message, 0);
}
async function appendErrorLog(brainDir2, script, message, exitCode = 1) {
  const entry = {
    timestamp: (/* @__PURE__ */ new Date()).toISOString().replace(/\.\d{3}Z$/, "Z"),
    script,
    message,
    exit_code: exitCode
  };
  let note = "";
  try {
    await fs2.mkdir(brainDir2, { recursive: true });
    await fs2.appendFile(join2(brainDir2, "error-log.jsonl"), JSON.stringify(entry) + "\n");
  } catch (e) {
    note = ` (error-log.jsonl write failed: ${e instanceof Error ? e.message : String(e)})`;
  }
  try {
    process.stderr.write(`[${script}] ${message}${note}
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
var PEER_PREFIX = "Another Claude session sent a message:";
var MACHINE_TAG_PREFIXES = [
  "<task-notification>",
  "<system-reminder>",
  "<agent-message",
  "<cross-session-message",
  "<command-",
  // command-name, command-message, command-args
  "<local-command-",
  // local-command-stdout, local-command-caveat, …
  "<bash-"
  // bash-input, bash-stdout, bash-stderr (the ! shell mode)
];
var MACHINE_TURN_PREFIXES = [
  ...MACHINE_TAG_PREFIXES,
  PEER_PREFIX,
  "Stop hook feedback:",
  "This session is being continued from a previous conversation",
  // Archive-only: the harness writes these as user turns, but they never reach the hook as a prompt.
  "Base directory for this skill:",
  "Caveat: The messages below were generated"
];
var MACHINE_LINE_PREFIXES = ["[Image: source:", "[Image: original", "[Request interrupted by user"];
function stripLead(text) {
  return text.replace(/^[\s﻿]+/, "");
}
function isMachineTurnText(text) {
  const t = stripLead(text);
  return MACHINE_TURN_PREFIXES.some((p) => t.startsWith(p)) || MACHINE_LINE_PREFIXES.some((p) => t.startsWith(p));
}
var SUBAGENT_REPORT_MARK = "(subagent report) ";
var PEER_MESSAGE_MARK = "(peer message) ";
function peerReportBody(rest) {
  const lines2 = rest.split("\n");
  let i = 0;
  while (i < lines2.length && !lines2[i].trim()) i++;
  const open = lines2[i]?.trim().match(/^<([a-z]+(?:-[a-z]+)+)\b[^>]*>(.*)$/);
  let body;
  if (open) {
    const close = `</${open[1]}>`;
    body = [open[2], ...lines2.slice(i + 1)];
    const end = body.findIndex((l) => l.trim().startsWith(close));
    if (end >= 0) body = body.slice(0, end);
  } else {
    body = lines2.slice(i);
  }
  const flags = [];
  let j = 0;
  for (; j < body.length; j++) {
    const l = body[j].trim();
    if (!l || l.startsWith("[Subagent hand-back]")) continue;
    if (l.startsWith("[harness:")) {
      flags.push(foldServedSnippet(l));
      continue;
    }
    break;
  }
  const report = body.slice(j).join("\n").trim();
  if (!report) return "";
  const mark = open?.[1] === "agent-message" ? SUBAGENT_REPORT_MARK : PEER_MESSAGE_MARK;
  return mark + [report, ...flags].join("\n");
}
var FOLD_TO_SPACE = /* @__PURE__ */ new Set([9, 10, 11, 12, 13, 133, 8232, 8233]);
var FOLD_TO_OPEN = /* @__PURE__ */ new Set([91, 65339, 12304, 10214, 12314, 8261, 65095, 12308]);
var FOLD_TO_CLOSE = /* @__PURE__ */ new Set([93, 65341, 12305, 10215, 12315, 8262, 65096, 12309]);
function foldServedSnippet(text) {
  let out = "";
  for (const ch of text) {
    const c = ch.codePointAt(0);
    out += FOLD_TO_SPACE.has(c) ? " " : FOLD_TO_OPEN.has(c) ? "(" : FOLD_TO_CLOSE.has(c) ? ")" : ch;
  }
  return out;
}
function cleanUserText(text) {
  if (!isMachineTurnText(text)) return text;
  const t = stripLead(text);
  if (MACHINE_LINE_PREFIXES.some((p) => t.startsWith(p))) {
    const lines2 = t.split("\n");
    let i = 0;
    while (i < lines2.length && (!lines2[i].trim() || MACHINE_LINE_PREFIXES.some((p) => stripLead(lines2[i]).startsWith(p)))) i++;
    const rest = lines2.slice(i).join("\n").trim();
    return rest ? cleanUserText(rest) : "";
  }
  if (t.startsWith(PEER_PREFIX)) return peerReportBody(t.slice(PEER_PREFIX.length));
  return "";
}
function servableEpisodes(rows, o) {
  const seen = /* @__PURE__ */ new Set();
  const out = [];
  for (const r of rows) {
    const userSnippet = cleanUserText(r.userSnippet);
    if (r.similarity < o.minSimilarity || !userSnippet.trim()) continue;
    if (o.sessionId && r.sessionId === o.sessionId) continue;
    const key = userSnippet.slice(0, 60);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ ...r, userSnippet });
    if (out.length >= o.max) break;
  }
  return out;
}
var EPISODIC_SERVE_HEADER = "[Past sessions \u2014 use episodic_search for full context]";
var SERVE_MIN_SIMILARITY = 0.15;
var SERVE_POOL = 10;
var SERVE_MAX = 2;
async function serveEpisodicLines(query2, brainDir2, o) {
  const result = await episodicSearch({
    query: query2,
    limit: SERVE_POOL,
    mode: "both",
    activeProject: o.activeProject,
    excludeSessionId: o.sessionId || void 0,
    requireUserText: true,
    minSimilarity: SERVE_MIN_SIMILARITY
  }, brainDir2);
  const served = servableEpisodes(
    result.results,
    { sessionId: o.sessionId, minSimilarity: SERVE_MIN_SIMILARITY, max: SERVE_MAX }
  );
  if (served.length === 0) return [];
  return [EPISODIC_SERVE_HEADER, ...served.map((r) => {
    const sim = Math.round(r.similarity * 100);
    return `- "${foldServedSnippet(r.userSnippet).slice(0, 80)}..." (${foldServedSnippet(r.project)}, ${foldServedSnippet(r.date)}, ${sim}%)`;
  })];
}
var emptyIndex = () => ({ model: "Xenova/all-MiniLM-L6-v2", indexed_files: {}, exchanges: [] });
async function loadIndex(brainDir2) {
  const indexPath = join3(brainDir2, INDEX_FILE);
  let data;
  try {
    data = await fs3.readFile(indexPath, "utf-8");
  } catch (e) {
    if (e.code === "ENOENT") return emptyIndex();
    await appendErrorLog(
      brainDir2,
      "episodic-index",
      `corrupt episodic index reset: ${indexPath} unreadable (${e instanceof Error ? e.message : String(e)})`
    );
    return emptyIndex();
  }
  let parsed;
  try {
    parsed = JSON.parse(data);
  } catch (e) {
    await appendErrorLog(
      brainDir2,
      "episodic-index",
      `corrupt episodic index reset: ${indexPath} is not JSON (${e instanceof Error ? e.message : String(e)})`
    );
    return emptyIndex();
  }
  const o = parsed;
  if (!o || typeof o !== "object" || Array.isArray(o) || !Array.isArray(o.exchanges)) {
    await appendErrorLog(
      brainDir2,
      "episodic-index",
      `corrupt episodic index reset: ${indexPath} has no exchanges array`
    );
    return emptyIndex();
  }
  const files = o.indexed_files;
  return {
    model: typeof o.model === "string" ? o.model : emptyIndex().model,
    indexed_files: files && typeof files === "object" && !Array.isArray(files) ? files : {},
    exchanges: o.exchanges
  };
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
  const seen = /* @__PURE__ */ new Set();
  const merged = [];
  for (const r of vectorResults) {
    if (!seen.has(r.id)) {
      seen.add(r.id);
      merged.push(r);
    }
  }
  for (const r of textResults) {
    if (!seen.has(r.id)) {
      seen.add(r.id);
      merged.push(r);
    }
  }
  merged.sort((a, b) => b.similarity - a.similarity);
  return {
    results: scopeAndBroaden(aboveFloor(merged, args), args).slice(0, limit).map((r) => ({
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
    aboveFloor(scored.filter((s) => s.minSimilarity >= threshold).sort((a, b) => b.similarity - a.similarity), filters),
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
  let result = exchanges;
  if (filters.project) {
    const p = filters.project.toLowerCase();
    result = result.filter((e) => e.project.toLowerCase() === p);
  }
  if (filters.after) {
    result = result.filter((e) => e.date >= filters.after);
  }
  if (filters.before) {
    result = result.filter((e) => e.date <= filters.before);
  }
  if (filters.excludeSessionId) {
    const sid = filters.excludeSessionId;
    result = result.filter((e) => e.sessionId !== sid);
  }
  if (filters.requireUserText) {
    result = result.filter((e) => cleanUserText(e.userSnippet).trim() !== "");
  }
  return result;
}
function aboveFloor(ranked, filters) {
  const floor = filters.minSimilarity;
  return floor === void 0 ? ranked : ranked.filter((r) => r.similarity >= floor);
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
var sessionId = process.env.SB_SESSION_ID?.trim() || "";
var lines = await serveEpisodicLines(query, brainDir, { sessionId, activeProject });
for (const l of lines) console.log(l);
