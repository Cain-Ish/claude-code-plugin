// src/tools/episodic-search.ts
import { promises as fs2 } from "fs";
import { join as join2, basename } from "path";

// src/tools/embeddings.ts
import { promises as fs } from "fs";
import { join } from "path";
var EMBEDDING_DIM = 384;
var CACHE_FILE = ".embeddings-cache.json";
var MODEL_ID = "Xenova/all-MiniLM-L6-v2";
var pipelineInstance = null;
var loadFailed = false;
async function getPipeline() {
  if (loadFailed) return null;
  if (pipelineInstance) return pipelineInstance;
  try {
    const { pipeline } = await import("@huggingface/transformers");
    pipelineInstance = await pipeline("feature-extraction", MODEL_ID, {
      dtype: "fp32"
    });
    return pipelineInstance;
  } catch {
    loadFailed = true;
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
    const data = await fs.readFile(join(wikiRoot, CACHE_FILE), "utf-8");
    const parsed = JSON.parse(data);
    if (parsed.model === MODEL_ID) return parsed;
  } catch {
  }
  return { model: MODEL_ID, entries: {} };
}
async function saveCache(wikiRoot, cache) {
  try {
    await fs.writeFile(join(wikiRoot, CACHE_FILE), JSON.stringify(cache));
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
  const indexPath = join2(brainDir2, INDEX_FILE);
  try {
    const data = await fs2.readFile(indexPath, "utf-8");
    return JSON.parse(data);
  } catch {
    return { model: "Xenova/all-MiniLM-L6-v2", indexed_files: {}, exchanges: [] };
  }
}
async function saveIndex(brainDir2, index) {
  await fs2.writeFile(join2(brainDir2, INDEX_FILE), JSON.stringify(index));
}
async function buildEpisodicIndex(brainDir2) {
  const archiveDir = join2(brainDir2, "transcripts");
  let files;
  try {
    const entries = await fs2.readdir(archiveDir);
    files = entries.filter((f) => f.endsWith(".txt")).map((f) => join2(archiveDir, f));
  } catch {
    return { indexed: 0, total: 0 };
  }
  const index = await loadIndex(brainDir2);
  const newExchanges = [];
  const currentFiles = {};
  for (const filePath of files) {
    const content = await fs2.readFile(filePath, "utf-8");
    const hash = simpleHash2(content);
    const fname = basename(filePath);
    currentFiles[fname] = hash;
    if (index.indexed_files[fname] === hash) continue;
    index.exchanges = index.exchanges.filter((e) => basename(e.archivePath) !== fname);
    const lines = content.split("\n");
    const { meta, bodyStart } = parseSessionMeta(lines);
    const exchanges = parseExchanges(lines, bodyStart, meta, filePath);
    newExchanges.push(...exchanges);
  }
  const validFiles = new Set(files.map((f) => basename(f)));
  index.exchanges = index.exchanges.filter((e) => validFiles.has(basename(e.archivePath)));
  if (newExchanges.length > 0) {
    const texts = newExchanges.map(
      (e) => `${e.userMessage}
${e.assistantMessage}`.slice(0, EMBEDDING_TEXT_CAP)
    );
    const paths = newExchanges.map((e) => `episodic:${e.id}`);
    const embeddings = await embedTexts(texts, join2(brainDir2, "transcripts"), paths);
    for (let i = 0; i < newExchanges.length; i++) {
      const e = newExchanges[i];
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
        embedding: embeddings?.[i] ?? []
      });
    }
  }
  index.indexed_files = currentFiles;
  await saveIndex(brainDir2, index);
  return { indexed: newExchanges.length, total: index.exchanges.length };
}

// src/tools/episodic-index-cli.ts
import { join as join3 } from "path";
var brainDir = process.env.BRAIN_DIR || join3(process.env.HOME ?? "", ".second-brain");
var result = await buildEpisodicIndex(brainDir);
if (result.indexed > 0) {
  console.error(`episodic-index: indexed ${result.indexed} new exchanges (${result.total} total)`);
}
