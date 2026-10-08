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
function installVectorDepsCommand(scriptPath) {
  const p = (scriptPath ?? "").replace(/\\/g, "/");
  const cut = p.lastIndexOf("/mcp/dist/");
  if (cut < 0) return 'bash "$CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh"';
  const script = `${p.slice(0, cut)}/bin/install-vector-deps.sh`;
  return `bash "${script.replace(/(["$`])/g, "\\$1")}"`;
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
    const hint = msg.includes("Cannot find package") ? ` \u2014 run: ${installVectorDepsCommand(process.argv[1])}` : "";
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
function isFiniteVector(v) {
  return Array.isArray(v) && v.every(Number.isFinite);
}
async function embedTexts(texts, wikiRoot, paths) {
  const pipe = await getPipeline();
  if (!pipe) return null;
  const cache = paths.some((p) => p) ? await loadCache(wikiRoot) : { model: MODEL_ID, entries: {} };
  const results = [];
  let cacheUpdated = false;
  for (let i = 0; i < texts.length; i++) {
    const hash = simpleHash(texts[i]);
    const key = paths[i] || `query-${i}`;
    const hit = cache.entries[key];
    if (hit?.hash === hash && isFiniteVector(hit.vector)) {
      results.push(hit.vector);
      continue;
    }
    const output = await pipe(texts[i], { pooling: "mean", normalize: true });
    const vec = Array.from(output.data).slice(0, EMBEDDING_DIM);
    results.push(vec);
    if (paths[i] && isFiniteVector(vec)) {
      cache.entries[key] = { hash, vector: vec };
      cacheUpdated = true;
    }
  }
  if (cacheUpdated) await saveCache(wikiRoot, cache);
  return results;
}

// src/tools/episodic-search.ts
var INDEX_FILE = "episodic-index.json";
var DEFAULT_LIMIT = 10;
var MAX_LIMIT = 30;
function quantizeEmbedding(vec) {
  let maxAbs = 0;
  for (let i = 0; i < vec.length; i++) {
    const a = Math.abs(vec[i]);
    if (a > maxAbs) maxAbs = a;
  }
  const es = maxAbs / 127;
  const q = new Int8Array(vec.length);
  if (es > 0) for (let i = 0; i < vec.length; i++) q[i] = Math.max(-127, Math.min(127, Math.round(vec[i] / es)));
  return { e8: Buffer.from(q.buffer, q.byteOffset, q.byteLength).toString("base64"), es };
}
function decodeE8(e8) {
  const b = Buffer.from(e8, "base64");
  return new Int8Array(b.buffer, b.byteOffset, b.byteLength);
}
function dotDequantized(query2, v, es) {
  let dot = 0;
  const n = Math.min(query2.length, v.length);
  for (let i = 0; i < n; i++) dot += query2[i] * v[i];
  return dot * es;
}
function embeddingSimilarity(query2, row) {
  return dotDequantized(query2, decodeE8(row.e8), row.es);
}
function hasVector(e) {
  return typeof e.e8 === "string" && e.e8.length > 0;
}
function currentRow(stored) {
  const { embedding, e8, es, ...row } = stored;
  if (typeof e8 === "string" && e8) {
    const ok = typeof es === "number" && Number.isFinite(es) && es >= 0 && decodeE8(e8).length === EMBEDDING_DIM;
    return ok ? { row: { ...row, e8, es }, dropped: false } : { row, dropped: true };
  }
  if (Array.isArray(embedding) && embedding.length > 0) {
    const ok = embedding.length === EMBEDDING_DIM && embedding.every((x) => typeof x === "number" && Number.isFinite(x));
    return ok ? { row: { ...row, ...quantizeEmbedding(embedding) }, dropped: false } : { row, dropped: true };
  }
  return { row, dropped: false };
}
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
var cps = (...xs) => String.fromCodePoint(...xs);
var ZWNJ = cps(8204);
var ZWJ = cps(8205);
var FOLD_SPACE_RE = /[\p{Cc}\p{Cf}\p{Zs}\p{Zl}\p{Zp}]/gu;
var FOLD_OPEN_EXTRA = cps(9121, 9122, 9123, 8988, 8990, 9150, 9151, 9484, 9492, 9500);
var FOLD_CLOSE_EXTRA = cps(9124, 9125, 9126, 8989, 8991, 9163, 9164, 9488, 9496, 9508);
var FOLD_OPEN_RE = new RegExp(`[\\p{Ps}\\p{Pi}${FOLD_OPEN_EXTRA}]`, "gu");
var FOLD_CLOSE_RE = new RegExp(`[\\p{Pe}\\p{Pf}${FOLD_CLOSE_EXTRA}]`, "gu");
var FOLD_QUOTE_KEEP = new Set(cps(
  8218,
  8222,
  11842,
  12317,
  12318,
  12319,
  171,
  187,
  8216,
  8217,
  8219,
  8220,
  8221,
  8223,
  8249,
  8250
));
var FRAME_PHRASE_SKELETON = "untrustedreference";
var CONFUSABLE = /* @__PURE__ */ new Map();
for (const [latin, from] of [
  ["c", [1089, 962, 963, 7428, 42202]],
  ["d", [1281, 7429, 42195]],
  ["e", [1077, 949, 1108, 7431, 42224]],
  ["f", [989, 42800, 42205]],
  ["n", [951, 957, 1087, 1400, 628, 42208]],
  ["r", [1075, 640, 638, 42211]],
  ["s", [1109, 42801, 42210]],
  ["t", [964, 1090, 7451, 42196]],
  ["u", [965, 1405, 7452, 651, 42228]]
]) {
  for (const c of from) CONFUSABLE.set(cps(c), latin);
}
var LETTER_OR_DIGIT_RE = /^[\p{L}\p{N}]$/u;
var SKELETON_CACHE = /* @__PURE__ */ new Map();
function skeletonOf(ch) {
  const c = ch.codePointAt(0) ?? 0;
  if (c < 128) {
    if (c >= 97 && c <= 122 || c >= 48 && c <= 57) return ch;
    return c >= 65 && c <= 90 ? String.fromCharCode(c + 32) : "";
  }
  let s = SKELETON_CACHE.get(c);
  if (s === void 0) {
    s = "";
    for (const d of ch.normalize("NFKD").toLowerCase().normalize("NFKD")) {
      const m = CONFUSABLE.get(d) ?? d;
      if (LETTER_OR_DIGIT_RE.test(m)) s += m;
    }
    if (SKELETON_CACHE.size < 4096) SKELETON_CACHE.set(c, s);
  }
  return s;
}
function neutraliseFramePhrase(text) {
  let skeleton = "";
  for (const ch of text) skeleton += skeletonOf(ch);
  if (!skeleton.includes(FRAME_PHRASE_SKELETON)) return text;
  const start = [], end = [];
  let i = 0;
  for (const ch of text) {
    const n = skeletonOf(ch).length;
    for (let k = 0; k < n; k++) {
      start.push(i);
      end.push(i + ch.length);
    }
    i += ch.length;
  }
  let out = "", last = 0;
  for (let j = skeleton.indexOf(FRAME_PHRASE_SKELETON); j >= 0; j = skeleton.indexOf(FRAME_PHRASE_SKELETON, j + FRAME_PHRASE_SKELETON.length)) {
    out += `${text.slice(last, Math.max(start[j], last))}untrusted-reference`;
    last = end[j + FRAME_PHRASE_SKELETON.length - 1];
  }
  return out + text.slice(last);
}
function foldServedSnippet(text) {
  return neutraliseFramePhrase(text.replace(FOLD_SPACE_RE, (m) => m === ZWNJ || m === ZWJ ? m : " ").replace(FOLD_OPEN_RE, (m) => m === "(" || m === "{" || FOLD_QUOTE_KEEP.has(m) ? m : "(").replace(FOLD_CLOSE_RE, (m) => m === ")" || m === "}" || FOLD_QUOTE_KEEP.has(m) ? m : ")"));
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
var ROW_STRING_FIELDS = ["id", "sessionId", "project", "date", "userSnippet", "assistantSnippet", "archivePath"];
function isStoredRow(v) {
  if (!v || typeof v !== "object" || Array.isArray(v)) return false;
  const o = v;
  return ROW_STRING_FIELDS.every((k) => typeof o[k] === "string");
}
async function loadIndex(brainDir2) {
  const indexPath = join3(brainDir2, INDEX_FILE);
  const reset = { index: emptyIndex(), dropped: 0, malformed: 0 };
  let data;
  try {
    data = await fs3.readFile(indexPath, "utf-8");
  } catch (e) {
    if (e.code === "ENOENT") return reset;
    await appendErrorLog(
      brainDir2,
      "episodic-index",
      `corrupt episodic index reset: ${indexPath} unreadable (${e instanceof Error ? e.message : String(e)})`
    );
    return reset;
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
    return reset;
  }
  const o = parsed;
  if (!o || typeof o !== "object" || Array.isArray(o) || !Array.isArray(o.exchanges)) {
    await appendErrorLog(
      brainDir2,
      "episodic-index",
      `corrupt episodic index reset: ${indexPath} has no exchanges array`
    );
    return reset;
  }
  const files = o.indexed_files;
  const indexedFiles = files && typeof files === "object" && !Array.isArray(files) ? files : {};
  let dropped = 0;
  let malformed = 0;
  const exchanges = [];
  for (const stored of o.exchanges) {
    if (!isStoredRow(stored)) {
      malformed++;
      const archivePath = stored?.archivePath;
      if (typeof archivePath === "string") delete indexedFiles[basename(archivePath)];
      continue;
    }
    const r = currentRow(stored);
    if (r.dropped) dropped++;
    exchanges.push(r.row);
  }
  return {
    index: {
      model: typeof o.model === "string" ? o.model : emptyIndex().model,
      indexed_files: indexedFiles,
      exchanges
    },
    dropped,
    malformed
  };
}
var SCRUB_MARK = ".archive-scrub-v1";
var SCRUB_TODO = `${SCRUB_MARK}.todo`;
async function episodicSearch(args, brainDir2) {
  const { index } = await loadIndex(brainDir2);
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
  const withEmbeddings = filtered.filter(hasVector);
  if (withEmbeddings.length === 0) return { hits: [], unavailable: filtered.length > 0 };
  const queryEmbedding = await embedTexts(
    [query2],
    join3(brainDir2, "transcripts"),
    [""]
  );
  if (!queryEmbedding) return { hits: [], unavailable: true };
  const qVec = queryEmbedding[0];
  return {
    hits: withEmbeddings.map((e) => ({ ...e, similarity: embeddingSimilarity(qVec, e) })).sort((a, b) => b.similarity - a.similarity).slice(0, limit),
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
  const withEmbeddings = filtered.filter(hasVector);
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
    const v = decodeE8(e.e8);
    const similarities = conceptEmbeddings.map((cv) => dotDequantized(cv, v, e.es));
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
