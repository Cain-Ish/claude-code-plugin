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
async function logLoadError(message, brainDir) {
  if (!lastLoadError || lastLoadError.msg !== message) {
    lastLoadError = { msg: message, loggedTo: /* @__PURE__ */ new Set() };
  }
  if (lastLoadError.loggedTo.has(brainDir)) return;
  lastLoadError.loggedTo.add(brainDir);
  const entry = {
    timestamp: (/* @__PURE__ */ new Date()).toISOString().replace(/\.\d{3}Z$/, "Z"),
    script: "embeddings",
    message,
    exit_code: 0
  };
  try {
    await fs.mkdir(brainDir, { recursive: true });
    await fs.appendFile(join(brainDir, "error-log.jsonl"), JSON.stringify(entry) + "\n");
  } catch {
  }
  try {
    process.stderr.write(`[embeddings] ${message}
`);
  } catch {
  }
}
async function getPipeline() {
  const brainDir = brainDirFromEnv();
  if (process.env[DISABLE_ENV] === "1") {
    await logLoadError(`embeddings disabled via ${DISABLE_ENV}=1 \u2014 episodic vector search and hybrid knowledge ranking unavailable`, brainDir);
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
    await logLoadError(`transformers model load failed: ${msg}${hint}`, brainDir);
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

// src/tools/egress-budget.ts
var CHARS_PER_TOKEN = 4;
function estimateTokens(text) {
  if (!text) return 0;
  return Math.ceil(text.length / CHARS_PER_TOKEN);
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
    description: doc.description || rawContent.slice(0, SNIPPET_CHARS).replace(/\s+/g, " ").trim(),
    tokens: estimateTokens(rawContent)
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

// src/tools/knowledge-search-cli.ts
var query = process.argv[2] || "";
if (!query) {
  process.exit(0);
}
var knowledgeDir = process.env.KNOWLEDGE_DIR || void 0;
var minScore = parseFloat(process.env.KNOWLEDGE_MIN_SCORE || "0");
var result = await knowledgeSearch({ query, knowledgeDir });
var top = result.candidates.filter((c) => c.score >= minScore).slice(0, 2);
if (top.length === 0) {
  process.exit(0);
}
for (const c of top) {
  const slug = c.path.replace(/.*\//, "").replace(/\.md$/, "");
  console.log(`### [[${slug}]]${c.description ? " \u2014 " + c.description : ""}`);
}
