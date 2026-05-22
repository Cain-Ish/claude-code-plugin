// src/cli/sb-entry.ts
import { join as join7 } from "path";

// src/cli/sb.ts
import { promises as fs6 } from "fs";
import { join as join6 } from "path";

// src/tools/knowledge-search.ts
import { promises as fs2 } from "fs";
import { join as join2 } from "path";

// src/tools/embeddings.ts
import { promises as fs } from "fs";
import { join } from "path";
var EMBEDDING_DIM = 384;
var CACHE_FILE = ".embeddings-cache.json";
var MODEL_ID = "Xenova/all-MiniLM-L6-v2";
var DISABLE_ENV = "SECOND_BRAIN_DISABLE_EMBEDDINGS";
var pipelineInstance = null;
var lastLoadError = null;
function brainDirFromEnv() {
  return process.env.BRAIN_DIR || join(process.env.HOME ?? "", ".second-brain");
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
    await fs.mkdir(brainDir2, { recursive: true });
    await fs.appendFile(join(brainDir2, "error-log.jsonl"), JSON.stringify(entry) + "\n");
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
    await logLoadError(`embeddings disabled via ${DISABLE_ENV}=1 \u2014 episodic vector search and hybrid knowledge ranking unavailable`, brainDir2);
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
function cosineSimilarity(a, b) {
  let dot = 0;
  for (let i = 0; i < a.length; i++) dot += a[i] * b[i];
  return dot;
}

// src/tools/knowledge-search.ts
var ACCESS_COUNTS_FILE = join2(process.env.HOME ?? "", ".second-brain", "access-counts.json");
var ACCESS_BOOST_FACTOR = 0.1;
var ACCESS_BOOST_CAP = 10;
var ACCESS_PRUNE_DAYS = 90;
async function loadAccessCounts() {
  try {
    return JSON.parse(await fs2.readFile(ACCESS_COUNTS_FILE, "utf-8"));
  } catch {
    return {};
  }
}
async function saveAccessCounts(counts) {
  const cutoff = new Date(Date.now() - ACCESS_PRUNE_DAYS * 864e5).toISOString();
  const pruned = {};
  for (const [k, v] of Object.entries(counts)) {
    if (v.last_accessed >= cutoff) pruned[k] = v;
  }
  await fs2.writeFile(ACCESS_COUNTS_FILE, JSON.stringify(pruned)).catch(() => {
  });
}
var TOP_K = 8;
var SNIPPET_CHARS = 200;
var BM25_K1 = 1.2;
var BM25_B = 0.75;
var AVG_DOC_LENGTH = 200;
var DATE_TOKEN_RE = /^\d{4}$|^\d{2}$/;
var MIN_SCORE_RATIO = 0.15;
var STUB_PENALTY = 0.5;
var MIN_SUBSTANTIVE_LENGTH = 100;
var AUTO_EXTRACTED_RE = /<!--\s*auto-extracted/;
async function knowledgeSearch(args) {
  const knowledgeDir2 = args.knowledgeDir ?? join2(process.env.HOME ?? "", "knowledge");
  const wikiRoot = join2(knowledgeDir2, "wiki");
  let scopeDirs;
  if (args.scope) {
    scopeDirs = [join2(wikiRoot, args.scope)];
  } else {
    try {
      const entries = await fs2.readdir(wikiRoot, { withFileTypes: true });
      scopeDirs = entries.filter((d) => d.isDirectory()).map((d) => join2(wikiRoot, d.name));
    } catch {
      scopeDirs = [];
    }
  }
  const queryTokens = tokenize(args.query).filter((t) => !isDateToken(t));
  if (queryTokens.length === 0) return { candidates: [] };
  const allDocs = [];
  for (const dir of scopeDirs) {
    let paths = [];
    try {
      paths = await collectMarkdown(dir);
    } catch {
      continue;
    }
    for (const filePath of paths) {
      try {
        const content = await fs2.readFile(filePath, "utf-8");
        const doc = parseDoc(content, filePath);
        allDocs.push({ doc, rawContent: content });
      } catch {
        continue;
      }
    }
  }
  if (allDocs.length === 0) return { candidates: [] };
  const avgDL = allDocs.reduce((sum, { doc }) => sum + tokenize(doc.body).length, 0) / allDocs.length || AVG_DOC_LENGTH;
  const N = allDocs.length;
  const dfMap = computeDF(queryTokens, allDocs.map(({ doc }) => doc));
  const scored = allDocs.map(({ doc, rawContent }) => ({
    path: doc.path,
    score: scoreBM25(queryTokens, doc, avgDL, N, dfMap),
    related: doc.related,
    first_lines: rawContent.slice(0, SNIPPET_CHARS)
  }));
  const slugScoreMap = new Map(scored.map((s) => [slugFromPath(s.path), s]));
  const GRAPH_BOOST = 0.3;
  for (const entry of scored) {
    if (entry.score <= 0) continue;
    for (const rel of entry.related) {
      const target = slugScoreMap.get(rel);
      if (target && target !== entry) {
        target.score += entry.score * GRAPH_BOOST;
      }
    }
  }
  const RRF_K = 60;
  try {
    const docTexts = allDocs.map(({ doc }) => `${doc.title} ${doc.description} ${doc.body}`.slice(0, 512));
    const docPaths = allDocs.map(({ doc }) => doc.path);
    const allTexts = [args.query, ...docTexts];
    const allPaths = ["", ...docPaths];
    const embeddings = await embedTexts(allTexts, wikiRoot, allPaths);
    if (embeddings) {
      const bm25Only = scored.map((s) => s.score);
      const queryVec = embeddings[0];
      const cosineScores = embeddings.slice(1).map((v) => cosineSimilarity(queryVec, v));
      const bm25Ranked = scored.map((s, i) => ({ i, score: s.score })).sort((a, b) => b.score - a.score);
      const cosineRanked = cosineScores.map((s, i) => ({ i, score: s })).sort((a, b) => b.score - a.score);
      const rrfScores = new Array(scored.length).fill(0);
      for (let rank = 0; rank < bm25Ranked.length; rank++) {
        rrfScores[bm25Ranked[rank].i] += 1 / (RRF_K + rank + 1);
      }
      for (let rank = 0; rank < cosineRanked.length; rank++) {
        rrfScores[cosineRanked[rank].i] += 1 / (RRF_K + rank + 1);
      }
      for (let i = 0; i < scored.length; i++) {
        scored[i].score = bm25Only[i] > 0 ? Math.round(rrfScores[i] * 1e4) / 1e4 : 0;
      }
    }
  } catch {
  }
  for (let i = 0; i < scored.length; i++) {
    const { doc, rawContent } = allDocs[i];
    if (AUTO_EXTRACTED_RE.test(rawContent) || doc.body.trim().length < MIN_SUBSTANTIVE_LENGTH) {
      scored[i].score *= STUB_PENALTY;
    }
  }
  const accessCounts = await loadAccessCounts();
  for (let i = 0; i < scored.length; i++) {
    if (scored[i].score <= 0) continue;
    const slug = slugFromPath(scored[i].path);
    const ac = accessCounts[slug];
    if (ac) {
      scored[i].score *= 1 + ACCESS_BOOST_FACTOR * Math.min(ac.count, ACCESS_BOOST_CAP);
    }
  }
  const RECENCY_BOOST_MAX = 0.3;
  const RECENCY_WINDOW_DAYS = 90;
  const now = Date.now();
  for (let i = 0; i < scored.length; i++) {
    if (scored[i].score <= 0) continue;
    const dateStr = allDocs[i].doc.updated || allDocs[i].doc.created;
    if (!dateStr) continue;
    const updated = new Date(dateStr).getTime();
    if (isNaN(updated)) continue;
    const daysSince = (now - updated) / 864e5;
    scored[i].score *= 1 + RECENCY_BOOST_MAX * Math.max(0, 1 - daysSince / RECENCY_WINDOW_DAYS);
  }
  scored.sort((a, b) => b.score - a.score);
  const topScore = scored[0]?.score ?? 0;
  const candidates = scored.filter((c) => c.score > 0 && (topScore === 0 || c.score >= topScore * MIN_SCORE_RATIO)).slice(0, TOP_K).map(({ related, ...rest }) => rest);
  const ts = (/* @__PURE__ */ new Date()).toISOString();
  for (const c of candidates) {
    const slug = slugFromPath(c.path);
    if (!accessCounts[slug]) accessCounts[slug] = { count: 0, last_accessed: "" };
    accessCounts[slug].count++;
    accessCounts[slug].last_accessed = ts;
  }
  saveAccessCounts(accessCounts).catch(() => {
  });
  return { candidates };
}
function computeDF(queryTokens, docs) {
  const dfMap = /* @__PURE__ */ new Map();
  for (const qt of queryTokens) {
    if (isDateToken(qt)) continue;
    let df = 0;
    for (const doc of docs) {
      const allTokens = [
        ...tokenize(doc.title),
        ...tokenize(doc.description),
        ...tokenize(doc.tags.join(" ")),
        ...tokenize(doc.body)
      ];
      if (allTokens.includes(qt)) df++;
    }
    dfMap.set(qt, df);
  }
  return dfMap;
}
function scoreBM25(queryTokens, doc, avgDL, N, dfMap) {
  const fields = [
    { tokens: tokenize(doc.title), weight: 3 },
    { tokens: tokenize(doc.description), weight: 2 },
    { tokens: tokenize(doc.tags.join(" ")), weight: 2 },
    { tokens: tokenize(doc.body), weight: 1 }
  ];
  let score = 0;
  for (const qt of queryTokens) {
    if (isDateToken(qt)) continue;
    const df = dfMap.get(qt) ?? 0;
    const idf = Math.log((N - df + 0.5) / (df + 0.5) + 1);
    for (const field of fields) {
      const tf = field.tokens.filter((t) => t === qt).length;
      if (tf === 0) continue;
      const dl = field.tokens.length || 1;
      const tfNorm = tf * (BM25_K1 + 1) / (tf + BM25_K1 * (1 - BM25_B + BM25_B * dl / avgDL));
      score += idf * tfNorm * field.weight;
    }
  }
  return Math.round(score * 100) / 100;
}
function parseDoc(content, filePath) {
  const doc = {
    title: "",
    description: "",
    type: "",
    tags: [],
    related: [],
    body: content,
    path: filePath,
    updated: "",
    created: ""
  };
  const fmMatch = content.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  if (fmMatch) {
    const fm = fmMatch[1];
    doc.body = fmMatch[2];
    doc.title = extractYamlValue(fm, "title");
    doc.description = extractYamlValue(fm, "description");
    doc.type = extractYamlValue(fm, "type");
    doc.tags = extractYamlList(fm, "tags");
    doc.related = extractYamlList(fm, "related");
    doc.updated = extractYamlValue(fm, "updated");
    doc.created = extractYamlValue(fm, "created");
  }
  if (!doc.title) {
    const headingMatch = doc.body.match(/^#\s+(.+)/m);
    if (headingMatch) doc.title = headingMatch[1].trim();
  }
  if (!doc.type) {
    const rel = filePath.split("/");
    const wikiIdx = rel.lastIndexOf("wiki");
    if (wikiIdx >= 0 && wikiIdx + 1 < rel.length) {
      doc.type = rel[wikiIdx + 1];
    }
  }
  if (doc.related.length === 0) {
    const wikiLinks = doc.body.match(/\[\[([^\]]+)\]\]/g);
    if (wikiLinks) {
      doc.related = [...new Set(wikiLinks.map((l) => l.slice(2, -2)))];
    }
  }
  return doc;
}
function extractYamlValue(yaml, key) {
  const re = new RegExp(`^${key}:\\s*['"]?(.+?)['"]?\\s*$`, "m");
  const m = yaml.match(re);
  return m ? m[1].trim() : "";
}
function extractYamlList(yaml, key) {
  const lineMatch = yaml.match(new RegExp(`^${key}:[ \\t]+(\\S.*?)\\s*$`, "m"));
  if (lineMatch) {
    const value = lineMatch[1];
    const wikiLinks = value.match(/\[\[([^\]\[]+)\]\]/g);
    if (wikiLinks && wikiLinks.length > 0) {
      return [...new Set(
        wikiLinks.map((l) => l.slice(2, -2).trim()).filter(Boolean)
      )];
    }
  }
  const inline = yaml.match(new RegExp(`^${key}:\\s*\\[(.+?)\\]`, "m"));
  if (inline) {
    return inline[1].split(",").map((s) => s.trim().replace(/^['"]|['"]$/g, "")).filter(Boolean);
  }
  const items = [];
  const lines = yaml.split("\n");
  let collecting = false;
  for (const line of lines) {
    if (line.match(new RegExp(`^${key}:`))) {
      collecting = true;
      continue;
    }
    if (collecting) {
      const itemMatch = line.match(/^\s+-\s+(.+)/);
      if (itemMatch) {
        items.push(itemMatch[1].trim().replace(/^['"]|['"]$/g, ""));
      } else {
        collecting = false;
      }
    }
  }
  return items;
}
function tokenize(s) {
  return s.toLowerCase().match(/[a-z0-9]+/g) ?? [];
}
function isDateToken(t) {
  return DATE_TOKEN_RE.test(t);
}
function slugFromPath(p) {
  return p.replace(/.*\//, "").replace(/\.md$/, "");
}
async function collectMarkdown(dir, acc = []) {
  for (const e of await fs2.readdir(dir, { withFileTypes: true })) {
    const p = join2(dir, e.name);
    if (e.isDirectory()) await collectMarkdown(p, acc);
    else if (e.isFile() && e.name.endsWith(".md") && e.name !== "index.md") acc.push(p);
  }
  return acc;
}

// src/tools/episodic-search.ts
import { promises as fs3 } from "fs";
import { join as join3, basename } from "path";
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
  const query = args.query;
  if (Array.isArray(query)) {
    return multiConceptSearch(query, index, limit, args);
  }
  const mode = args.mode ?? "both";
  let vectorResults = [];
  let textResults = [];
  if (mode === "vector" || mode === "both") {
    vectorResults = await vectorSearch(query, index, limit * 2, args, brainDir2);
  }
  if (mode === "text" || mode === "both") {
    textResults = textSearch(query, index, limit * 2, args);
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
    results: merged.slice(0, limit).map((r) => ({
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
async function vectorSearch(query, index, limit, filters, brainDir2) {
  const filtered = applyFilters(index.exchanges, filters);
  const withEmbeddings = filtered.filter((e) => e.embedding.length > 0);
  if (withEmbeddings.length === 0) return [];
  const queryEmbedding = await embedTexts(
    [query],
    join3(brainDir2, "transcripts"),
    [""]
  );
  if (!queryEmbedding) return [];
  const qVec = queryEmbedding[0];
  return withEmbeddings.map((e) => ({ ...e, similarity: cosineSimilarity(qVec, e.embedding) })).sort((a, b) => b.similarity - a.similarity).slice(0, limit);
}
function textSearch(query, index, limit, filters) {
  const filtered = applyFilters(index.exchanges, filters);
  const tokens = query.toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length >= 2);
  if (tokens.length === 0) return [];
  const scored = [];
  for (const e of filtered) {
    const hay = (e.userSnippet + " " + e.assistantSnippet).toLowerCase();
    let hits = 0;
    for (const t of tokens) {
      if (hay.includes(t)) hits++;
      else {
        hits = -1;
        break;
      }
    }
    if (hits === tokens.length) {
      scored.push({ ...e, similarity: 0.25 + hits / tokens.length * 0.25 });
    }
  }
  return scored.slice(0, limit);
}
async function multiConceptSearch(concepts, index, limit, filters) {
  const brainDir2 = index.exchanges[0]?.archivePath ? join3(index.exchanges[0].archivePath, "..", "..") : join3(process.env.HOME ?? "", ".second-brain");
  const filtered = applyFilters(index.exchanges, filters);
  const withEmbeddings = filtered.filter((e) => e.embedding.length > 0);
  if (withEmbeddings.length === 0) return { results: [] };
  const conceptEmbeddings = await embedTexts(
    concepts,
    join3(brainDir2, "transcripts"),
    concepts.map((_, i) => `concept-${i}`)
  );
  if (!conceptEmbeddings) return { results: [] };
  const scored = withEmbeddings.map((e) => {
    const similarities = conceptEmbeddings.map((cv) => cosineSimilarity(cv, e.embedding));
    const minSim = Math.min(...similarities);
    const avgSim = similarities.reduce((a, b) => a + b, 0) / similarities.length;
    return { ...e, similarity: avgSim, minSimilarity: minSim };
  });
  const threshold = 0.2;
  return {
    results: scored.filter((s) => s.minSimilarity >= threshold).sort((a, b) => b.similarity - a.similarity).slice(0, limit).map((r) => ({
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

// src/tools/pin-to-user.ts
import { promises as fs4 } from "fs";
import { join as join4 } from "path";
var MAX_LINES = 15;
async function pinToUser(args) {
  const dir = args.brainDir ?? join4(process.env.HOME ?? "", ".second-brain");
  const file = join4(dir, "USER.md");
  const date = (/* @__PURE__ */ new Date()).toISOString().slice(0, 10);
  const trimmed = args.text.trim();
  const newLine = `- [${date}] ${trimmed}`;
  let content = "";
  try {
    content = await fs4.readFile(file, "utf-8");
  } catch {
    content = "# USER preferences\n\n## Pinned\n";
  }
  const existing = content.split("\n").find((l) => {
    const m = l.match(/^- \[\d{4}-\d{2}-\d{2}\]\s+(.*)$/);
    return m !== null && m[1].trim() === trimmed;
  });
  if (existing !== void 0) {
    return { ok: true, line_added: existing, reason: "already present" };
  }
  const projected = content + (content.endsWith("\n") ? "" : "\n") + newLine + "\n";
  if (projected.split("\n").filter(Boolean).length > MAX_LINES) {
    return { ok: false, line_added: "", reason: `would exceed ${MAX_LINES}-line cap` };
  }
  await fs4.mkdir(dir, { recursive: true });
  await fs4.writeFile(file, projected, "utf-8");
  return { ok: true, line_added: newLine };
}

// src/tools/pin-to-project.ts
import { promises as fs5 } from "fs";
import { join as join5 } from "path";
var SECTION_HEADER = { blockers: "## Open blockers", decisions: "## Recent decisions" };
var ENTRY_PREFIX = { blockers: "- [active] ", decisions: "- [decision] " };
async function pinToProject(args) {
  if (!(args.section in SECTION_HEADER)) {
    return { ok: false, line_added: "", project_slug: args.slug, reason: "unknown section" };
  }
  const dir = args.brainDir ?? join5(process.env.HOME ?? "", ".second-brain");
  const file = join5(dir, "projects", args.slug, "PROJECT.md");
  const content = await fs5.readFile(file, "utf-8");
  const sectionHeader = SECTION_HEADER[args.section];
  const newEntry = `${ENTRY_PREFIX[args.section]}${args.text.trim()}`;
  const lines = content.split("\n");
  const idx = lines.findIndex((line) => line.trim() === sectionHeader);
  if (idx < 0) {
    return { ok: false, line_added: "", project_slug: args.slug, reason: `section ${sectionHeader} not found` };
  }
  let endIdx = lines.length;
  for (let i = idx + 1; i < lines.length; i++) {
    if (lines[i].startsWith("## ")) {
      endIdx = i;
      break;
    }
  }
  while (endIdx > idx + 1 && lines[endIdx - 1].trim() === "") endIdx--;
  const trimmed = args.text.trim();
  const prefix = ENTRY_PREFIX[args.section];
  for (let i = idx + 1; i < endIdx; i++) {
    if (lines[i].startsWith(prefix) && lines[i].slice(prefix.length).trim() === trimmed) {
      return { ok: true, line_added: lines[i], project_slug: args.slug, reason: "already present" };
    }
  }
  lines.splice(endIdx, 0, newEntry);
  await fs5.writeFile(file, lines.join("\n"), "utf-8");
  return { ok: true, line_added: newEntry, project_slug: args.slug };
}

// src/cli/sb.ts
var HELP = `Usage: sb <command> [args]

Commands:
  query <text>                                 Search the wiki (BM25 + vector hybrid)
  recall <text>                                Search past conversation transcripts
  pin user <text>                              Append a preference line to USER.md
  pin project <slug> <blockers|decisions> <text>
                                               Append an entry to a project's PROJECT.md
  status                                       Show hot-tier and wiki sizes
  help                                         Show this message

Environment:
  BRAIN_DIR        Override second-brain dir (default: ~/.second-brain)
  KNOWLEDGE_DIR    Override knowledge dir    (default: ~/knowledge)
`;
async function runSb(args, deps) {
  const out = [];
  const err = [];
  const push = (s) => out.push(s);
  const errpush = (s) => err.push(s);
  if (args.length === 0 || args[0] === "help" || args[0] === "--help" || args[0] === "-h") {
    push(HELP);
    return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
  }
  const cmd = args[0];
  if (cmd === "query") {
    const q = args.slice(1).join(" ").trim();
    if (!q) {
      errpush("query: missing search text");
      return { stdout: "", stderr: err.join("\n"), exitCode: 2 };
    }
    const r = await knowledgeSearch({ query: q, knowledgeDir: deps.knowledgeDir });
    if (r.candidates.length === 0) {
      push("(no results)");
    }
    for (const c of r.candidates.slice(0, 5)) {
      const slug = c.path.replace(/.*[\\/]/, "").replace(/\.md$/, "");
      const score = (c.score * 100).toFixed(0);
      const firstLine = c.first_lines.split("\n").find((l) => /^description:/.test(l))?.replace(/^description:\s*['"]?/, "").replace(/['"]?\s*$/, "") ?? "";
      push(`${score.padStart(3)}%  [[${slug}]]${firstLine ? "  \u2014 " + firstLine : ""}`);
      push(`       ${c.path}`);
    }
    return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
  }
  if (cmd === "recall") {
    const q = args.slice(1).join(" ").trim();
    if (!q) {
      errpush("recall: missing search text");
      return { stdout: "", stderr: err.join("\n"), exitCode: 2 };
    }
    const r = await episodicSearch({ query: q, limit: 5 }, deps.brainDir);
    if (r.results.length === 0) {
      push("(no results \u2014 only sessions with substantive tool use are archived)");
    }
    for (const x of r.results) {
      const sim = Math.round(x.similarity * 100);
      push(`${String(sim).padStart(3)}%  [${x.date} ${x.project}]  ${x.userSnippet.slice(0, 100)}`);
      push(`       ${x.archivePath}:${x.lineStart}-${x.lineEnd}`);
    }
    return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
  }
  if (cmd === "pin") {
    const sub = args[1];
    if (sub === "user") {
      const text = args.slice(2).join(" ").trim();
      if (!text) {
        errpush("pin user: missing text");
        return { stdout: "", stderr: err.join("\n"), exitCode: 2 };
      }
      const r = await pinToUser({ text, brainDir: deps.brainDir });
      if (!r.ok) {
        errpush(`pin user: ${r.reason ?? "failed"}`);
        return { stdout: "", stderr: err.join("\n"), exitCode: 1 };
      }
      push(`+ ${r.line_added}${r.reason ? "  (" + r.reason + ")" : ""}`);
      return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
    }
    if (sub === "project") {
      const slug = args[2];
      const section = args[3];
      const text = args.slice(4).join(" ").trim();
      if (!slug || !section || !text) {
        errpush("pin project: usage: sb pin project <slug> <blockers|decisions> <text>");
        return { stdout: "", stderr: err.join("\n"), exitCode: 2 };
      }
      const r = await pinToProject({ text, slug, section, brainDir: deps.brainDir });
      if (!r.ok) {
        errpush(`pin project: ${r.reason ?? "failed"}`);
        return { stdout: "", stderr: err.join("\n"), exitCode: 1 };
      }
      push(`+ ${r.line_added}  (${slug}/${section})${r.reason ? "  " + r.reason : ""}`);
      return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
    }
    errpush(`pin: unknown subcommand '${sub ?? ""}'`);
    return { stdout: "", stderr: err.join("\n"), exitCode: 2 };
  }
  if (cmd === "status") {
    const userFile = join6(deps.brainDir, "USER.md");
    const projectsFile = join6(deps.brainDir, "projects.jsonl");
    let userBytes = 0, projectsCount = 0;
    try {
      userBytes = (await fs6.stat(userFile)).size;
    } catch {
    }
    try {
      const txt = await fs6.readFile(projectsFile, "utf-8");
      projectsCount = txt.split("\n").filter((l) => l.includes('"slug"')).length;
    } catch {
    }
    push(`USER.md:             ${userBytes} bytes`);
    push(`Registered projects: ${projectsCount}`);
    try {
      const projectDirs = await fs6.readdir(join6(deps.brainDir, "projects"), { withFileTypes: true });
      for (const d of projectDirs) {
        if (!d.isDirectory()) continue;
        const pf = join6(deps.brainDir, "projects", d.name, "PROJECT.md");
        try {
          const size = (await fs6.stat(pf)).size;
          push(`  ${d.name}/PROJECT.md: ${size} bytes`);
        } catch {
        }
      }
    } catch {
    }
    try {
      const wikiDirs = await fs6.readdir(join6(deps.knowledgeDir, "wiki"), { withFileTypes: true });
      push("Wiki pages:");
      for (const d of wikiDirs) {
        if (!d.isDirectory()) continue;
        const files = await fs6.readdir(join6(deps.knowledgeDir, "wiki", d.name));
        const count = files.filter((f) => f.endsWith(".md") && f !== "index.md").length;
        push(`  ${d.name}: ${count}`);
      }
    } catch {
    }
    return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
  }
  errpush(`unknown command: ${cmd}`);
  errpush("run: sb help");
  return { stdout: "", stderr: err.join("\n"), exitCode: 2 };
}

// src/cli/sb-entry.ts
var brainDir = process.env.BRAIN_DIR || join7(process.env.HOME ?? process.env.USERPROFILE ?? "", ".second-brain");
var knowledgeDir = process.env.KNOWLEDGE_DIR || process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR || join7(process.env.HOME ?? process.env.USERPROFILE ?? "", "knowledge");
var result = await runSb(process.argv.slice(2), { brainDir, knowledgeDir });
if (result.stdout) process.stdout.write(result.stdout + "\n");
if (result.stderr) process.stderr.write(result.stderr + "\n");
process.exit(result.exitCode);
