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

// src/tools/sanitize.ts
var INVISIBLE_RE = /[\u{200B}\u{2060}\u{FEFF}\u{E0000}-\u{E007F}]/gu;
function stripInvisible(s) {
  return s.replace(INVISIBLE_RE, "");
}

// src/tools/episodic-search.ts
var INDEX_FILE = "episodic-index.json";
var SNIPPET_LEN = 200;
var EMBEDDING_TEXT_CAP = 512;
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
async function saveIndex(brainDir2, index) {
  await atomicWriteJson(join3(brainDir2, INDEX_FILE), index);
}
async function buildEpisodicIndex(brainDir2) {
  const archiveDir = join3(brainDir2, "transcripts");
  let files;
  try {
    const entries = await fs3.readdir(archiveDir);
    files = entries.filter((f) => f.endsWith(".txt")).map((f) => join3(archiveDir, f));
  } catch {
    return { indexed: 0, total: 0, repaired: 0, pending: 0 };
  }
  const index = await loadIndex(brainDir2);
  const newExchanges = [];
  const reparsed = {};
  const previous = /* @__PURE__ */ new Map();
  for (const filePath of files) {
    const content = stripInvisible(await fs3.readFile(filePath, "utf-8"));
    const hash = simpleHash2(content);
    const fname = basename(filePath);
    if (isCurrentEntry(index.indexed_files[fname], hash)) continue;
    reparsed[fname] = hash;
    for (const e of index.exchanges) if (basename(e.archivePath) === fname) previous.set(e.id, e);
    index.exchanges = index.exchanges.filter((e) => basename(e.archivePath) !== fname);
    const lines = content.split("\n");
    const { meta, bodyStart } = parseSessionMeta(lines);
    newExchanges.push(...parseExchanges(lines, bodyStart, meta, filePath));
  }
  const validFiles = new Set(files.map((f) => basename(f)));
  index.exchanges = index.exchanges.filter((e) => validFiles.has(basename(e.archivePath)));
  for (const e of newExchanges) {
    const userSnippet = e.userMessage.slice(0, SNIPPET_LEN);
    const assistantSnippet = e.assistantMessage.slice(0, SNIPPET_LEN);
    const old = previous.get(e.id);
    const carried = old && old.userSnippet === userSnippet && old.assistantSnippet === assistantSnippet && Array.isArray(old.embedding) && old.embedding.length > 0 ? old.embedding : [];
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
      embedding: carried
    });
  }
  const needsEmbed = index.exchanges.filter((e) => !e.embedding || e.embedding.length === 0);
  let repaired = 0;
  if (needsEmbed.length > 0) {
    const texts = needsEmbed.map((r) => `${r.userSnippet}
${r.assistantSnippet}`.slice(0, EMBEDDING_TEXT_CAP));
    const paths = needsEmbed.map((r) => `episodic:${r.id}`);
    const embeddings = await embedTexts(texts, join3(brainDir2, "transcripts"), paths);
    if (embeddings) {
      for (let i = 0; i < needsEmbed.length; i++) {
        if (embeddings[i] && embeddings[i].length > 0) {
          needsEmbed[i].embedding = embeddings[i];
          repaired++;
        }
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
  const pending = index.exchanges.filter((e) => !e.embedding || e.embedding.length === 0).length;
  if (pending > 0 && !embeddingsOptedOut()) {
    await appendErrorLog(
      brainDir2,
      "episodic-index",
      `${pending} of ${index.exchanges.length} rows have no embedding after the repair pass: vector recall misses them until a build can embed them (check the embedding model / vector deps)`
    );
  }
  return { indexed: newExchanges.length, total: index.exchanges.length, repaired, pending };
}

// src/tools/episodic-index-cli.ts
var brainDir = resolveBrainDir();
var result = await buildEpisodicIndex(brainDir);
if (result.indexed > 0) {
  console.error(`episodic-index: indexed ${result.indexed} new exchanges (${result.total} total)`);
}
