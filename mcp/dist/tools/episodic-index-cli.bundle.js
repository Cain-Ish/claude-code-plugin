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
  try {
    await fs2.writeFile(join2(wikiRoot, CACHE_FILE), JSON.stringify(cache));
  } catch {
  }
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
          userMessage: user,
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
async function loadIndex(brainDir2) {
  const indexPath = join3(brainDir2, INDEX_FILE);
  try {
    const data = await fs3.readFile(indexPath, "utf-8");
    return JSON.parse(data);
  } catch {
    return { model: "Xenova/all-MiniLM-L6-v2", indexed_files: {}, exchanges: [] };
  }
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
  const fileHashes = {};
  for (const filePath of files) {
    const content = stripInvisible(await fs3.readFile(filePath, "utf-8"));
    const hash = simpleHash2(content);
    const fname = basename(filePath);
    fileHashes[fname] = hash;
    if (index.indexed_files[fname] === hash) continue;
    index.exchanges = index.exchanges.filter((e) => basename(e.archivePath) !== fname);
    const lines = content.split("\n");
    const { meta, bodyStart } = parseSessionMeta(lines);
    newExchanges.push(...parseExchanges(lines, bodyStart, meta, filePath));
  }
  const validFiles = new Set(files.map((f) => basename(f)));
  index.exchanges = index.exchanges.filter((e) => validFiles.has(basename(e.archivePath)));
  for (const e of newExchanges) {
    index.exchanges.push({
      id: e.id,
      sessionId: e.sessionId,
      project: e.project,
      date: e.date,
      userSnippet: e.userMessage.slice(0, SNIPPET_LEN),
      assistantSnippet: e.assistantMessage.slice(0, SNIPPET_LEN),
      archivePath: e.archivePath,
      lineStart: e.lineStart,
      lineEnd: e.lineEnd,
      embedding: []
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
  for (const [fname, hash] of Object.entries(fileHashes)) {
    index.indexed_files[fname] = hash;
  }
  for (const fname of Object.keys(index.indexed_files)) {
    if (!validFiles.has(fname)) delete index.indexed_files[fname];
  }
  await saveIndex(brainDir2, index);
  const pending = index.exchanges.filter((e) => !e.embedding || e.embedding.length === 0).length;
  return { indexed: newExchanges.length, total: index.exchanges.length, repaired, pending };
}

// src/tools/episodic-index-cli.ts
var brainDir = resolveBrainDir();
var result = await buildEpisodicIndex(brainDir);
if (result.indexed > 0) {
  console.error(`episodic-index: indexed ${result.indexed} new exchanges (${result.total} total)`);
}
