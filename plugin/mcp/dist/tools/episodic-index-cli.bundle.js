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
var strictWriteCounter = 0;
async function atomicWriteJsonStrict(filePath, value) {
  const tmp = `${filePath}.tmp.${process.pid}.${Date.now()}.${strictWriteCounter++}`;
  try {
    await fs.writeFile(tmp, JSON.stringify(value));
    await fs.rename(tmp, filePath);
  } catch (err) {
    try {
      await fs.unlink(tmp);
    } catch {
    }
    throw err;
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
function embeddingsOptedOut() {
  return process.env[DISABLE_ENV] === "1";
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

// src/tools/sanitize.ts
var INVISIBLE_RE = /[\u{200B}\u{2060}\u{FEFF}\u{E0000}-\u{E007F}]/gu;
function stripInvisible(s) {
  return s.replace(INVISIBLE_RE, "");
}

// src/tools/episodic-search.ts
var INDEX_FILE = "episodic-index.json";
var SNIPPET_LEN = 200;
var EMBEDDING_TEXT_CAP = 512;
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
var EPISODIC_PARSER_VERSION = 3;
function isCurrentEntry(entry, hash) {
  return typeof entry === "object" && entry !== null && entry.hash === hash && entry.parser >= EPISODIC_PARSER_VERSION;
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
  const lines = rest.split("\n");
  let i = 0;
  while (i < lines.length && !lines[i].trim()) i++;
  const open = lines[i]?.trim().match(/^<([a-z]+(?:-[a-z]+)+)\b[^>]*>(.*)$/);
  let body;
  if (open) {
    const close = `</${open[1]}>`;
    body = [open[2], ...lines.slice(i + 1)];
    const end = body.findIndex((l) => l.trim().startsWith(close));
    if (end >= 0) body = body.slice(0, end);
  } else {
    body = lines.slice(i);
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
    const lines = t.split("\n");
    let i = 0;
    while (i < lines.length && (!lines[i].trim() || MACHINE_LINE_PREFIXES.some((p) => stripLead(lines[i]).startsWith(p)))) i++;
    const rest = lines.slice(i).join("\n").trim();
    return rest ? cleanUserText(rest) : "";
  }
  if (t.startsWith(PEER_PREFIX)) return peerReportBody(t.slice(PEER_PREFIX.length));
  return "";
}
function simpleHash2(s) {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = (h << 5) - h + s.charCodeAt(i) | 0;
  }
  return h.toString(36);
}
function parseSessionMeta(lines) {
  const meta = { sessionId: "", project: "", date: "" };
  let i = 0;
  if (lines[0]?.startsWith("--- session-meta ---")) {
    i = 1;
    while (i < lines.length && !lines[i].startsWith("---")) {
      const m = lines[i].match(/^(\w+):\s*(.+)/);
      if (m) {
        if (m[1] === "session_id") meta.sessionId = m[2].trim();
        else if (m[1] === "project_slug") meta.project = m[2].trim();
        else if (m[1] === "date") meta.date = m[2].trim();
      }
      i++;
    }
    i++;
    if (i < lines.length && lines[i] === "") i++;
  }
  return { meta, bodyStart: i };
}
function parseExchanges(lines, bodyStart, meta, archivePath) {
  const exchanges = [];
  let userMsg = "";
  let assistantMsg = "";
  let exchangeStart = bodyStart;
  let inUser = false;
  let inAssistant = false;
  const flush = (endLine) => {
    if (userMsg.trim() || assistantMsg.trim()) {
      const user = userMsg.trim();
      const assistant = assistantMsg.trim();
      if (user.length > 10 || assistant.length > 20) {
        exchanges.push({
          id: simpleHash2(`${archivePath}:${exchangeStart}-${endLine}`),
          sessionId: meta.sessionId,
          project: meta.project,
          date: meta.date,
          userMessage: cleanUserText(user),
          assistantMessage: assistant,
          archivePath,
          lineStart: exchangeStart + 1,
          // 1-indexed for Read tool
          lineEnd: endLine + 1
        });
      }
    }
    userMsg = "";
    assistantMsg = "";
  };
  for (let i = bodyStart; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith("USER:")) {
      if (inUser || inAssistant) flush(i - 1);
      exchangeStart = i;
      inUser = true;
      inAssistant = false;
      const rest = line.slice(5).trim();
      if (rest) userMsg += rest + "\n";
    } else if (line.startsWith("ASSISTANT:")) {
      if (!inUser && !inAssistant) {
        exchangeStart = i;
      }
      inAssistant = true;
      inUser = false;
      const rest = line.slice(10).trim();
      if (rest) assistantMsg += rest + "\n";
    } else if (inUser) {
      userMsg += line.trimStart() + "\n";
    } else if (inAssistant) {
      assistantMsg += line.trimStart() + "\n";
    }
  }
  flush(lines.length - 1);
  return exchanges;
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
async function saveIndex(brainDir2, index) {
  const indexPath = join3(brainDir2, INDEX_FILE);
  try {
    await atomicWriteJsonStrict(indexPath, index);
  } catch (e) {
    await appendErrorLog(
      brainDir2,
      "episodic-index",
      `episodic index write failed: ${indexPath} (${e instanceof Error ? e.message : String(e)}); the previous index is kept and the next build retries`
    );
  }
}
var SCRUB_MARK = ".archive-scrub-v1";
var SCRUB_TODO = `${SCRUB_MARK}.todo`;
function parseScrubTodo(text) {
  const entries = [];
  for (const raw of text.split("\n")) {
    const [first, fc = ""] = raw.replace(/\r$/, "").split("	");
    if (!first) continue;
    const path = first.includes("/") ? first : `transcripts/${first}`;
    entries.push({ path, fails: /^[0-9]+$/.test(fc) ? Number(fc) : 0 });
  }
  return entries;
}
async function scrubPendingArchives(brainDir2) {
  const pending = /* @__PURE__ */ new Set();
  try {
    await fs3.stat(join3(brainDir2, SCRUB_MARK));
    return pending;
  } catch {
  }
  const todoPath = join3(brainDir2, SCRUB_TODO);
  let text;
  try {
    text = await fs3.readFile(todoPath, "utf-8");
  } catch (e) {
    if (e.code !== "ENOENT") {
      await appendErrorLog(
        brainDir2,
        "episodic-index",
        `cannot read the archive-scrub to-do list ${todoPath} (${e instanceof Error ? e.message : String(e)}); nothing is held out of the episodic index, so archives the scrub has not reached yet are indexed in clear`
      );
    }
    return pending;
  }
  for (const { path } of parseScrubTodo(text)) {
    const m = /^transcripts\/([^/]+)$/.exec(path);
    if (m) pending.add(m[1]);
  }
  return pending;
}
async function buildEpisodicIndex(brainDir2) {
  const archiveDir = join3(brainDir2, "transcripts");
  let files;
  try {
    const entries = await fs3.readdir(archiveDir);
    files = entries.filter((f) => f.endsWith(".txt")).map((f) => join3(archiveDir, f));
  } catch {
    return { indexed: 0, total: 0, repaired: 0, pending: 0, held: 0 };
  }
  const scrubPending = await scrubPendingArchives(brainDir2);
  let held = 0;
  const { index, dropped, malformed } = await loadIndex(brainDir2);
  if (malformed > 0) {
    await appendErrorLog(
      brainDir2,
      "episodic-index",
      `${malformed} malformed row(s) (not an object with the row's string fields) were dropped from the episodic index; an archive such a row names is re-parsed`
    );
  }
  if (dropped > 0) {
    await appendErrorLog(
      brainDir2,
      "episodic-index",
      `${dropped} stored vector(s) not ${EMBEDDING_DIM} components were dropped from the episodic index; those rows re-embed`
    );
  }
  const newExchanges = [];
  const reparsed = {};
  const previous = /* @__PURE__ */ new Map();
  for (const filePath of files) {
    const fname = basename(filePath);
    if (scrubPending.has(fname)) {
      delete index.indexed_files[fname];
      held++;
      continue;
    }
    const content = stripInvisible(await fs3.readFile(filePath, "utf-8"));
    const hash = simpleHash2(content);
    if (isCurrentEntry(index.indexed_files[fname], hash)) continue;
    reparsed[fname] = hash;
    for (const e of index.exchanges) if (basename(e.archivePath) === fname) previous.set(e.id, e);
    index.exchanges = index.exchanges.filter((e) => basename(e.archivePath) !== fname);
    const lines = content.split("\n");
    const { meta, bodyStart } = parseSessionMeta(lines);
    newExchanges.push(...parseExchanges(lines, bodyStart, meta, filePath));
  }
  const validFiles = new Set(files.map((f) => basename(f)));
  index.exchanges = index.exchanges.filter((e) => {
    const fname = basename(e.archivePath);
    return validFiles.has(fname) && !scrubPending.has(fname);
  });
  for (const e of newExchanges) {
    const userSnippet = e.userMessage.slice(0, SNIPPET_LEN);
    const assistantSnippet = e.assistantMessage.slice(0, SNIPPET_LEN);
    const old = previous.get(e.id);
    const carried = old && old.userSnippet === userSnippet && old.assistantSnippet === assistantSnippet && hasVector(old) ? { e8: old.e8, es: old.es } : {};
    index.exchanges.push({
      id: e.id,
      sessionId: e.sessionId,
      project: e.project,
      date: e.date,
      userSnippet,
      assistantSnippet,
      archivePath: e.archivePath,
      lineStart: e.lineStart,
      lineEnd: e.lineEnd,
      ...carried
    });
  }
  const needsEmbed = index.exchanges.filter((e) => !hasVector(e));
  let repaired = 0;
  if (needsEmbed.length > 0) {
    const texts = needsEmbed.map((r) => `${r.userSnippet}
${r.assistantSnippet}`.slice(0, EMBEDDING_TEXT_CAP));
    const paths = needsEmbed.map((r) => `episodic:${r.id}`);
    const embeddings = await embedTexts(texts, join3(brainDir2, "transcripts"), paths);
    if (embeddings) {
      let nonFinite = 0;
      for (let i = 0; i < needsEmbed.length; i++) {
        const vec = embeddings[i];
        if (!vec || vec.length !== EMBEDDING_DIM) continue;
        if (!vec.every(Number.isFinite)) {
          nonFinite++;
          continue;
        }
        Object.assign(needsEmbed[i], quantizeEmbedding(vec));
        repaired++;
      }
      if (nonFinite > 0) {
        await appendErrorLog(
          brainDir2,
          "episodic-index",
          `${nonFinite} embedding(s) with a non-finite component were not stored; those rows stay pending and the next build embeds them again (the embedding cache does not keep such a vector)`
        );
      }
    }
  }
  for (const [fname, hash] of Object.entries(reparsed)) {
    index.indexed_files[fname] = { hash, parser: EPISODIC_PARSER_VERSION };
  }
  for (const fname of Object.keys(index.indexed_files)) {
    if (!validFiles.has(fname)) delete index.indexed_files[fname];
  }
  await saveIndex(brainDir2, index);
  const pending = index.exchanges.filter((e) => !hasVector(e)).length;
  if (pending > 0 && !embeddingsOptedOut()) {
    await appendErrorLog(
      brainDir2,
      "episodic-index",
      `${pending} of ${index.exchanges.length} rows have no embedding after the repair pass: vector recall misses them until a build can embed them (check the embedding model / vector deps)`
    );
  }
  return { indexed: newExchanges.length, total: index.exchanges.length, repaired, pending, held };
}

// src/tools/episodic-index-cli.ts
var brainDir = resolveBrainDir();
var result = await buildEpisodicIndex(brainDir);
if (result.indexed > 0) {
  console.error(`episodic-index: indexed ${result.indexed} new exchanges (${result.total} total)`);
}
if (result.held > 0) {
  console.error(`episodic-index: ${result.held} archive(s) held out until the 0.56.0 secret scrub reaches them`);
}
