// src/tools/knowledge-search.ts
import { promises as fs7 } from "fs";

// src/tools/atomic-write.ts
import { promises as fs } from "fs";
var writeCounter = 0;
function uniqueTmp(filePath) {
  return `${filePath}.tmp.${process.pid}.${Date.now()}.${writeCounter++}`;
}
async function atomicWriteJson(filePath, value) {
  const tmp = uniqueTmp(filePath);
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

// src/tools/knowledge-search.ts
import { join as join7 } from "path";

// src/brain-paths.ts
import { join, isAbsolute as isAbsolute2 } from "path";
import { homedir } from "os";

// src/path-guard.ts
import { resolve, sep, isAbsolute } from "path";
import { realpathSync } from "fs";
var PathGuardError = class extends Error {
  constructor(message, baseDir, candidate) {
    super(message);
    this.baseDir = baseDir;
    this.candidate = candidate;
    this.name = "PathGuardError";
  }
  baseDir;
  candidate;
};
function realResolve(p) {
  let current = "";
  const segments = p.split(sep);
  let start = 0;
  if (/^[A-Za-z]:$/.test(segments[0])) {
    try {
      current = realpathSync(segments[0] + sep).replace(new RegExp(`\\${sep}+$`), "");
    } catch {
      current = segments[0];
    }
    start = 1;
  }
  for (let i = start; i < segments.length; i++) {
    const next = current === "" && segments[i] === "" ? sep : current === sep ? sep + segments[i] : /^[A-Za-z]:$/.test(current) ? current + sep + segments[i] : current === "" ? segments[i] : current + sep + segments[i];
    try {
      current = realpathSync(next);
    } catch {
      const rest = segments.slice(i + 1).join(sep);
      return rest ? current + sep + segments[i] + sep + rest : current + sep + segments[i];
    }
  }
  return current;
}
function assertWithin(baseDir, ...parts) {
  for (const part of parts) {
    if (part.indexOf("\0") !== -1) {
      throw new PathGuardError(`path component contains NUL byte`, baseDir, parts.join("/"));
    }
    if (isAbsolute(part)) {
      throw new PathGuardError(`absolute path component not allowed: ${JSON.stringify(part)}`, baseDir, parts.join("/"));
    }
  }
  const baseResolved = realResolve(resolve(baseDir));
  const candidate = resolve(baseDir, ...parts);
  const candidateResolved = realResolve(candidate);
  if (candidateResolved !== baseResolved && !candidateResolved.startsWith(baseResolved + sep)) {
    throw new PathGuardError(
      `path escapes base directory: ${candidateResolved} not within ${baseResolved}`,
      baseDir,
      parts.join("/")
    );
  }
  return candidateResolved;
}
function cleanEnvPath(s) {
  return (s ?? "").replace(/[\r\n]/g, "");
}
function assertSafeSlug(slug) {
  if (!slug || slug.length > 128 || /[\\/\x00-\x1f]|\.\./.test(slug)) {
    throw new Error(`unsafe slug: ${JSON.stringify(slug)}`);
  }
}
function validateSlug(slug) {
  if (typeof slug !== "string") {
    throw new PathGuardError("slug must be a string", "", String(slug));
  }
  if (slug.length === 0 || slug.length > 128) {
    throw new PathGuardError(`slug length must be 1..128, got ${slug.length}`, "", slug);
  }
  if (slug.startsWith(".")) {
    throw new PathGuardError(`slug must not start with '.': ${JSON.stringify(slug)}`, "", slug);
  }
  if (!/^[a-zA-Z0-9._-]+$/.test(slug)) {
    throw new PathGuardError(`slug contains disallowed characters: ${JSON.stringify(slug)}`, "", slug);
  }
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
function resolveKnowledgeDir(override) {
  if (override) return suiteGuard("knowledge", override);
  for (const raw of [process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR, process.env.KNOWLEDGE_DIR]) {
    const c = cleanEnvPath(raw);
    if (!c.trim() || c.includes("${")) continue;
    return suiteGuard("knowledge", c.startsWith("~") ? join(homedir(), c.slice(1)) : c);
  }
  return suiteGuard("knowledge", join(homedir(), "knowledge"));
}

// src/tools/embeddings.ts
import { promises as fs2 } from "fs";
import { join as join2 } from "path";
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
async function appendGateTrace(brainDir2, script, message) {
  const entry = {
    timestamp: (/* @__PURE__ */ new Date()).toISOString().replace(/\.\d{3}Z$/, "Z"),
    script,
    message,
    exit_code: 0
  };
  try {
    await fs2.mkdir(brainDir2, { recursive: true });
    await fs2.appendFile(join2(brainDir2, "audit-log.jsonl"), JSON.stringify(entry) + "\n");
  } catch (e) {
    const why = e instanceof Error ? e.message : String(e);
    try {
      process.stderr.write(`[${script}] ${message} (audit-log.jsonl write failed: ${why})
`);
    } catch {
    }
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

// src/tools/doc-registry.ts
import { promises as fs3, realpathSync as realpathSync2, existsSync } from "fs";
import { homedir as homedir2 } from "os";
import { join as join3, resolve as resolve2, sep as sep2, isAbsolute as isAbsolute3, parse, win32 } from "path";
function registryPath(brainDir2, slug) {
  return join3(brainDir2, "projects", slug, "doc-sources.json");
}
async function loadRegistry(brainDir2, slug) {
  try {
    assertSafeSlug(slug);
    return JSON.parse(await fs3.readFile(registryPath(brainDir2, slug), "utf-8"));
  } catch {
    return null;
  }
}
function isDocEntry(e) {
  if (!e || typeof e !== "object") return false;
  const o = e;
  return typeof o.path === "string" && typeof o.gist === "string" && typeof o.mtime === "string" && typeof o.size === "number" && Array.isArray(o.headings) && o.headings.every((h) => typeof h === "string");
}
function isPlainAbsolutePath(p, platform = process.platform) {
  const absolute = platform === "win32" ? /^([A-Za-z]:[\\/]|[\\/]{2}[^\\/])/.test(p) : p.startsWith("/");
  return absolute && !p.split(/[\\/]/).some((seg) => seg === "." || seg === "..");
}
function canonicalReal(p) {
  const r = realpathSync2.native(p);
  return process.platform === "win32" ? r.toLowerCase() : r;
}
function rootStatusOf(root, home) {
  if (parse(root).root === root) return "fs-root";
  if (!home) return "ok";
  let h;
  try {
    h = canonicalReal(home);
  } catch {
    h = resolve2(home);
    if (process.platform === "win32") h = h.toLowerCase();
  }
  return h === root || h.startsWith(root.endsWith(sep2) ? root : root + sep2) ? "home" : "ok";
}
function fromOtherCheckout(e, root) {
  const rel = typeof e.rel === "string" ? e.rel : "";
  if (!rel || isAbsolute3(rel) || win32.isAbsolute(rel) || rel.split(/[\\/]/).some((s) => s === "" || s === "." || s === "..")) return false;
  let path = e.path.replace(/\\/g, "/"), tail = `/${rel.replace(/\\/g, "/")}`;
  if (process.platform === "win32") {
    path = path.toLowerCase();
    tail = tail.toLowerCase();
  }
  return path.endsWith(tail) && existsSync(join3(root, rel));
}
function servableEntries(entries, projectRoot, home = homedir2()) {
  const r = {
    kept: [],
    outside: 0,
    otherCheckout: 0,
    relative: 0,
    missing: 0,
    malformed: 0,
    rootUsable: false,
    rootStatus: "unusable"
  };
  let root = "";
  try {
    if (projectRoot) {
      root = canonicalReal(cleanEnvPath(projectRoot));
      r.rootStatus = rootStatusOf(root, home);
    }
  } catch {
  }
  r.rootUsable = r.rootStatus === "ok";
  const prefix = root.endsWith(sep2) ? root : root + sep2;
  for (const e of Array.isArray(entries) ? entries : []) {
    if (!isDocEntry(e)) {
      r.malformed++;
      continue;
    }
    if (!isPlainAbsolutePath(e.path)) {
      r.relative++;
      continue;
    }
    let real;
    try {
      real = canonicalReal(e.path);
    } catch {
      r.missing++;
      continue;
    }
    if (!r.rootUsable || !real.startsWith(prefix)) {
      if (r.rootUsable && fromOtherCheckout(e, root)) r.otherCheckout++;
      else r.outside++;
      continue;
    }
    r.kept.push(e);
  }
  return r;
}

// src/tools/project-registry.ts
import { readFileSync } from "fs";
import { join as join4 } from "path";
function loadRegistry2(brainDir2) {
  let text;
  try {
    text = readFileSync(join4(brainDir2, "projects.jsonl"), "utf-8");
  } catch {
    return [];
  }
  const out = [];
  for (const line of text.split("\n")) {
    const s = line.trim();
    if (!s) continue;
    try {
      const r = JSON.parse(s);
      if (r && typeof r.slug === "string" && r.slug) out.push(r);
    } catch {
    }
  }
  return out;
}
function projectFamily(brainDir2, slug) {
  const recs = loadRegistry2(brainDir2);
  const self = recs.find((r) => r.slug === slug);
  const root = self?.parent ?? slug;
  const fam = /* @__PURE__ */ new Set([slug, root]);
  for (const r of recs) if ((r.parent ?? r.slug) === root) fam.add(r.slug);
  return fam;
}

// src/tools/project-dir.ts
function activeProjectDir(env = process.env, cwd = process.cwd) {
  return cleanEnvPath(env.CLAUDE_PROJECT_DIR) || cwd();
}

// src/tools/sanitize.ts
var INVISIBLE_RE = /[\u{200B}\u{2060}\u{FEFF}\u{E0000}-\u{E007F}]/gu;
function stripInvisible(s) {
  return s.replace(INVISIBLE_RE, "");
}

// src/tools/graph-store.ts
import { promises as fs4 } from "fs";
var EDGE_TYPES = ["requires", "affects", "relates", "part_of", "supersedes"];
function cmpTime(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}
function dateOf(iso) {
  return iso.slice(0, 10);
}
function isValidRecord(r) {
  if (!(r && typeof r === "object")) return false;
  if (r.op !== "assert" && r.op !== "invalidate") return false;
  if (typeof r.from !== "string" || r.from.length === 0) return false;
  if (typeof r.to !== "string" || r.to.length === 0) return false;
  if (!EDGE_TYPES.includes(r.type)) return false;
  if (typeof r.recorded_at !== "string" || r.recorded_at.length < 10) return false;
  for (const k of ["valid_from", "valid_to"]) {
    const v = r[k];
    if (v !== void 0 && v !== null && typeof v !== "string") return false;
  }
  return true;
}
async function loadEdges(path) {
  let raw;
  try {
    raw = await fs4.readFile(path, "utf-8");
  } catch {
    return [];
  }
  const out = [];
  for (const line of raw.split("\n")) {
    const t = line.trim();
    if (!t) continue;
    try {
      const parsed = JSON.parse(t);
      if (isValidRecord(parsed)) out.push(parsed);
    } catch {
    }
  }
  return out;
}
function identity(r) {
  return `${r.from}	${r.type}	${r.to}`;
}
function foldToCurrent(records) {
  const ordered = [...records].sort((a, b) => cmpTime(a.recorded_at, b.recorded_at));
  const map = /* @__PURE__ */ new Map();
  for (const r of ordered) {
    const id = identity(r);
    const cur = map.get(id);
    if (r.op === "assert") {
      if (!cur || cur.valid_to !== null) {
        map.set(id, {
          from: r.from,
          to: r.to,
          type: r.type,
          valid_from: r.valid_from ?? dateOf(r.recorded_at),
          valid_to: null,
          source: r.source,
          confidence: r.confidence
        });
      } else {
        if (r.valid_from != null) cur.valid_from = r.valid_from;
        if (r.source) cur.source = r.source;
        if (r.confidence) cur.confidence = r.confidence;
      }
    } else {
      if (cur) cur.valid_to = r.valid_to ?? dateOf(r.recorded_at);
    }
  }
  return [...map.values()];
}
function validAt(e, t) {
  const td = dateOf(t);
  if (cmpTime(dateOf(e.valid_from), td) > 0) return false;
  if (e.valid_to === null) return true;
  return cmpTime(dateOf(e.valid_to), td) > 0;
}

// ../kb-schema.json
var kb_schema_default = {
  _comment: "SINGLE SOURCE OF TRUTH for the second-brain knowledge-base structure. Edit HERE only. Read by the TS MCP server via mcp/src/constants/kb-schema.ts (esbuild inlines this JSON) and by every bash script/hook via scripts/kb-schema.sh (sourced by the scripts that read it, not by lib.sh; reads this file with jq). Derived sets (content/all categories) are computed by the loaders, never stored, so they cannot drift. Guarded by tests/test-kb-schema.sh.",
  structured_types: ["learnings", "decisions", "entities", "issues", "concepts", "security"],
  unstructured_types: ["state", "sources"],
  frontmatter_required: ["title", "description", "type", "created", "updated", "tags", "related"],
  ai_blocks: {
    markers: { begin: "<!-- ai:begin", end: "<!-- ai:end -->" },
    body: "flat YAML key: value lines",
    types: {
      learnings: { fields: ["claim", "trigger", "action", "scope", "evidence", "supersedes"], required: ["claim", "action"] },
      decisions: { fields: ["context", "choice", "alternatives", "rationale", "status", "supersedes"], required: ["choice"] },
      entities: { fields: ["identity", "current_state", "depends_on", "owns", "status"], required: ["identity"] },
      issues: { fields: ["symptom", "cause", "fix", "severity", "status"], required: ["symptom", "status"] },
      concepts: { fields: ["problem", "solution", "where_applied", "tradeoffs"], required: ["problem", "solution"] },
      security: { fields: ["threat", "mitigation", "scope", "status"], required: ["threat", "mitigation"] }
    }
  },
  candidate_facts: {
    _comment: "Stage A <-> Stage B contract for the P6 quarantined consolidation split. json_schema is passed VERBATIM to the Stage A summarizer spawn (claude -p --json-schema, validator-enforced from CLI 2.1.205) by scripts/maintain-llm-drain.sh (jq -c .candidate_facts.json_schema). The Stage B writer (mcp/src/tools/candidate-facts.ts) validates against the SAME object, deriving the kind vocabulary and byte caps from it - never a second copy. kind_to_category maps writable kinds to wiki categories; kinds absent from the map are handled elsewhere: `preference` is DROPPED (no consumer yet); `relation` carries from_hint/to_hint/rel and becomes a proposed EDGE (Stage B resolves the hints deterministically, dream-accept applies them via merge-edges.sh). `rel` is deliberately restricted to `relates` for the unattended lane - typed edges (requires/affects/part_of) and especially `supersedes` stay a live-maintainer judgement: a wrong typed edge distorts knowledge_neighbors blast-radius answers, and a wrong supersedes retires a true page.",
    kind_to_category: { decision: "decisions", learning: "learnings", entity: "entities", issue: "issues" },
    relation_edge_types: ["relates"],
    json_schema: {
      type: "object",
      additionalProperties: false,
      required: ["facts"],
      properties: {
        facts: {
          type: "array",
          maxItems: 200,
          items: {
            type: "object",
            additionalProperties: false,
            required: ["kind", "claim"],
            properties: {
              kind: { type: "string", enum: ["decision", "learning", "entity", "issue", "preference", "relation"] },
              from_hint: { type: "string", maxLength: 120 },
              to_hint: { type: "string", maxLength: 120 },
              rel: { type: "string", enum: ["relates"] },
              title: { type: "string", maxLength: 120 },
              claim: { type: "string", minLength: 1, maxLength: 2e3 },
              evidence: { type: "string", maxLength: 1e3 },
              source: { type: "string", maxLength: 300 },
              confidence: { type: "string", enum: ["high", "medium", "low"] }
            }
          }
        }
      }
    }
  },
  generated_dirs: ["projects", "themes"],
  edge_types: ["requires", "affects", "relates", "part_of", "supersedes"],
  forget_protection: {
    protected: ["learnings", "decisions", "concepts", "security", "themes", "projects"],
    discounted: ["entities", "sources", "issues"]
  }
};

// src/constants/kb-schema.ts
var STRUCTURED_TYPES = kb_schema_default.structured_types;
var UNSTRUCTURED_TYPES = kb_schema_default.unstructured_types;
var GENERATED_DIRS = kb_schema_default.generated_dirs;
var CANDIDATE_FACTS = kb_schema_default.candidate_facts;
var FRONTMATTER_REQUIRED = kb_schema_default.frontmatter_required;
var AI_BLOCK_TYPES = kb_schema_default.ai_blocks.types;
var CONTENT_CATEGORIES = [...STRUCTURED_TYPES, ...UNSTRUCTURED_TYPES];
var ALL_CATEGORIES = [...CONTENT_CATEGORIES, ...GENERATED_DIRS];

// src/tools/ai-block.ts
var AI_BLOCK_RE = /<!--\s*ai:begin[^\n]*?-->\n?([\s\S]*?)<!--\s*ai:end\s*-->/;
var AI_BLOCK_SCHEMAS = AI_BLOCK_TYPES;
function schemaFor(type) {
  return Object.prototype.hasOwnProperty.call(AI_BLOCK_SCHEMAS, type) ? AI_BLOCK_SCHEMAS[type] : void 0;
}
function parseAiBlock(content) {
  const m = content.match(AI_BLOCK_RE);
  if (!m) return null;
  const out = {};
  let last = "";
  for (const raw of m[1].split("\n")) {
    const line = raw.trimEnd();
    if (!line.trim()) continue;
    const kv = line.match(/^([a-z_][a-z0-9_]*):\s*(.*)$/i);
    if (kv) {
      last = kv[1];
      out[last] = kv[2].trim();
    } else if (last) {
      out[last] = (out[last] + " " + line.trim()).trim();
    }
  }
  return out;
}
var AI_BLOCK_RE_G = new RegExp(AI_BLOCK_RE.source, "g");
function stripAiBlock(text) {
  return text.replace(AI_BLOCK_RE_G, "");
}
function aiBlockSnippet(type, block) {
  const schema = schemaFor(type);
  const order = schema ? schema.fields : Object.keys(block);
  return order.filter((f) => (block[f] ?? "").trim()).map((f) => `${f}: ${block[f].trim()}`).join("; ");
}

// src/tools/frontmatter.ts
function stripBom(s) {
  return s.charCodeAt(0) === 65279 ? s.slice(1) : s;
}
function matchFrontmatter(content) {
  const m = stripBom(content).match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  return m ? { fm: m[1], body: m[2] } : null;
}
function extractYamlValue(yaml, key) {
  const re = new RegExp(`^${key}:\\s*['"]?(.*?)['"]?\\s*$`, "m");
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
    created: "",
    project: "",
    area: ""
  };
  let hasRelatedKey = false;
  const fmMatch = matchFrontmatter(content);
  if (fmMatch) {
    const fm = fmMatch.fm;
    doc.body = fmMatch.body;
    doc.title = extractYamlValue(fm, "title");
    doc.description = extractYamlValue(fm, "description");
    doc.type = extractYamlValue(fm, "type");
    doc.tags = extractYamlList(fm, "tags");
    doc.related = extractYamlList(fm, "related");
    hasRelatedKey = /^related:/m.test(fm);
    doc.updated = extractYamlValue(fm, "updated");
    doc.created = extractYamlValue(fm, "created");
    doc.project = extractYamlValue(fm, "project");
    doc.area = extractYamlValue(fm, "area");
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
  doc.aiBlock = parseAiBlock(content) ?? void 0;
  if (!hasRelatedKey) {
    const wikiLinks = stripAiBlock(doc.body).match(/\[\[([^\]]+)\]\]/g);
    if (wikiLinks) {
      doc.related = [...new Set(wikiLinks.map((l) => l.slice(2, -2)))];
    }
  }
  return doc;
}

// src/tools/walk-wiki.ts
import { promises as fs5 } from "fs";
import { join as join5 } from "path";
async function walkWiki(dir, opts = {}, acc = []) {
  let entries;
  try {
    entries = await fs5.readdir(dir, { withFileTypes: true });
  } catch {
    return acc;
  }
  for (const e of entries) {
    if (opts.skipHidden && e.name.startsWith(".")) continue;
    const p = join5(dir, e.name);
    if (e.isDirectory()) {
      if (opts.skipDirs?.includes(e.name)) continue;
      await walkWiki(p, opts, acc);
    } else if (e.isFile() && e.name.endsWith(".md") && (opts.includeIndex || e.name !== "index.md")) {
      acc.push(opts.posix ? p.replace(/\\/g, "/") : p);
    }
  }
  return acc;
}

// src/tools/episodic-search.ts
import { promises as fs6 } from "fs";
import { join as join6, basename, relative, isAbsolute as isAbsolute4 } from "path";
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
  const indexPath = join6(brainDir2, INDEX_FILE);
  const reset = { index: emptyIndex(), dropped: 0, malformed: 0 };
  let data;
  try {
    data = await fs6.readFile(indexPath, "utf-8");
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
    join6(brainDir2, "transcripts"),
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
    join6(brainDir2, "transcripts"),
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

// src/tools/knowledge-search.ts
function aiBlockText(doc) {
  return doc.aiBlock ? Object.values(doc.aiBlock).join(" ") : "";
}
function clampEnvInt(name, def, lo, hi) {
  const n = parseInt(process.env[name] ?? "", 10);
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : def;
}
function graphNeighbourhood(seeds, edges, hops) {
  const adj = /* @__PURE__ */ new Map();
  for (const e of edges) for (const [a, b] of [[e.from, e.to], [e.to, e.from]]) {
    if (!adj.has(a)) adj.set(a, []);
    adj.get(a).push(b);
  }
  const reached = new Set(seeds);
  let frontier = [...seeds];
  for (let h = 0; h < hops; h++) {
    const next = [];
    for (const node of frontier) for (const to of adj.get(node) ?? []) if (!reached.has(to)) {
      reached.add(to);
      next.push(to);
    }
    frontier = next;
  }
  return reached;
}
function accessCountsFile(brainDir2) {
  return join7(resolveBrainDir(brainDir2), "access-counts.json");
}
var ACCESS_PRUNE_DAYS = 90;
async function loadAccessCounts(file) {
  try {
    return JSON.parse(await fs7.readFile(file, "utf-8"));
  } catch {
    return {};
  }
}
async function saveAccessCounts(counts, file) {
  const cutoff = new Date(Date.now() - ACCESS_PRUNE_DAYS * 864e5).toISOString();
  const pruned = {};
  for (const [k, v] of Object.entries(counts)) {
    if (v.last_accessed >= cutoff) pruned[k] = v;
  }
  await atomicWriteJson(file, pruned);
}
var TOP_K = 8;
var SNIPPET_CHARS = 200;
var BM25_K1 = 1.2;
var BM25_B = 0.75;
var AVG_DOC_LENGTH = 200;
var DATE_TOKEN_RE = /^\d{4}$|^\d{2}$/;
var MIN_SCORE_RATIO = 0.15;
var STUB_PENALTY = 0.5;
var MIN_CORPUS_FOR_DF = 8;
var LEGACY_GROUNDING_STOPWORDS = /* @__PURE__ */ new Set([
  // the 0.54 list; SB_INJECT_PRECISION=off grounds on it alone
  "the",
  "a",
  "an",
  "and",
  "or",
  "but",
  "if",
  "then",
  "than",
  "that",
  "this",
  "these",
  "those",
  "is",
  "are",
  "was",
  "were",
  "be",
  "been",
  "being",
  "am",
  "do",
  "does",
  "did",
  "doing",
  "done",
  "have",
  "has",
  "had",
  "having",
  "can",
  "could",
  "will",
  "would",
  "should",
  "shall",
  "may",
  "might",
  "must",
  "i",
  "you",
  "we",
  "they",
  "he",
  "she",
  "it",
  "me",
  "my",
  "our",
  "your",
  "their",
  "its",
  "to",
  "of",
  "in",
  "on",
  "at",
  "by",
  "for",
  "with",
  "from",
  "into",
  "onto",
  "about",
  "as",
  "what",
  "when",
  "where",
  "which",
  "who",
  "whom",
  "why",
  "how",
  "not",
  "no",
  "yes",
  "so",
  "up",
  "down",
  "out",
  "off",
  "over",
  "under",
  "again",
  "here",
  "there",
  "best",
  "better",
  "good",
  "bad",
  "way",
  "ways",
  "thing",
  "things",
  "stuff",
  "get",
  "got",
  "make",
  "made",
  "use",
  "used",
  "using",
  "need",
  "want",
  "like",
  "please",
  "help",
  "some",
  "any",
  "all",
  "more",
  "most",
  "much",
  "many",
  "very",
  "just",
  "only",
  "also",
  "now"
]);
var GROUNDING_STOPWORDS = /* @__PURE__ */ new Set([
  ...LEGACY_GROUNDING_STOPWORDS,
  // Generic prompt verbs/qualifiers, added 2026-10 (R1#4) only after re-grading: on the 40 graded
  // prompts over the real wiki, none of these pushes a grader-identified R2 page below the gate,
  // and together they cut injections on noise-graded prompts 16 -> 10 (scratchpad
  // review/stopword-validation.md). Deliberately NOT here: "new" (grounds R2 #27, "season 8 ...
  // new artifacts") and "changes" (grounds R2 #38's version-bump tripwire page) — locked in
  // retrieval-guards.test.ts.
  "check",
  "checks",
  "checked",
  "one",
  "old",
  "add",
  "added",
  "change",
  "changed",
  "relevant",
  "correct",
  "valid",
  "everything",
  "update",
  "updated",
  "missing",
  "still",
  "final",
  "ready",
  "sure",
  "let",
  "see",
  "try",
  "continue"
]);
var COMMON_TERM_DF_SHARE = (() => {
  const v = parseFloat(process.env.SB_GROUNDING_DF_SHARE ?? "");
  return Number.isFinite(v) && v > 0 && v <= 1 ? v : 0.5;
})();
var MIN_SUBSTANTIVE_LENGTH = 100;
var AUTO_EXTRACTED_RE = /<!--\s*auto-extracted/;
var STUB_DESCRIPTION_RE = /^\s*Auto-created stub/;
var SINGLE_LETTER_RE = /^[a-z]$/;
var PURE_DIGITS_RE = /^[0-9]+$/;
var envNum = (name, def, lo, hi) => {
  const raw = process.env[name];
  if (raw === void 0 || raw === "") return def;
  const v = Number(raw);
  return Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : def;
};
var embedFailLogged = false;
async function knowledgeSearch(args) {
  const knowledgeDir2 = resolveKnowledgeDir(args.knowledgeDir);
  const wikiRoot = join7(knowledgeDir2, "wiki");
  const accessFile = accessCountsFile(args.brainDir);
  let scopeDirs;
  if (args.scope && args.scope !== "all") {
    try {
      validateSlug(args.scope);
    } catch (e) {
      throw new Error(`invalid scope ${JSON.stringify(args.scope)}: must be a single wiki subdirectory name, no path separators or '..' (${e instanceof Error ? e.message : String(e)})`);
    }
    scopeDirs = [assertWithin(wikiRoot, args.scope)];
  } else {
    try {
      const entries = await fs7.readdir(wikiRoot, { withFileTypes: true });
      scopeDirs = entries.filter((d) => d.isDirectory()).map((d) => join7(wikiRoot, d.name));
    } catch {
      scopeDirs = [];
    }
  }
  const queryTokens = tokenize(args.query).filter((t) => !isDateToken(t));
  if (queryTokens.length === 0) return { candidates: [] };
  const allDocs = [];
  for (const dir of scopeDirs) {
    const paths = await walkWiki(dir, { posix: true });
    for (const filePath of paths) {
      try {
        const content = await fs7.readFile(filePath, "utf-8");
        const doc = parseDoc(content, filePath);
        allDocs.push({ doc, rawContent: content, source: "wiki", tokens: estimateTokens(content) });
      } catch {
        continue;
      }
    }
  }
  const reg = args.brainDir && args.projectSlug ? await loadRegistry(args.brainDir, args.projectSlug) : null;
  if (reg && args.brainDir && args.projectSlug) {
    let root = args.projectRoot;
    if (root === void 0) {
      try {
        root = activeProjectDir();
      } catch {
        root = void 0;
      }
    }
    const s = servableEntries(reg.entries, root);
    const dropped = s.outside + s.otherCheckout + s.relative + s.missing + s.malformed;
    if (dropped > 0) {
      await appendGateTrace(
        args.brainDir,
        "knowledge-search",
        `gate=local-doc-drop slug=${args.projectSlug} kept=${s.kept.length} dropped=${dropped} outside=${s.outside} other_checkout=${s.otherCheckout} relative=${s.relative} missing=${s.missing} malformed=${s.malformed} root=${JSON.stringify(capCodePoints(cleanEnvPath(root), 300))} root_status=${s.rootStatus}`
      );
    }
    for (const e of s.kept) {
      const doc = {
        title: "",
        description: e.gist,
        type: "local-doc",
        tags: [],
        related: [],
        body: e.headings.join("\n"),
        path: e.path,
        updated: e.mtime,
        created: e.mtime,
        project: "",
        area: ""
      };
      allDocs.push({ doc, rawContent: `${e.gist}
${e.headings.join("\n")}`, source: "local-doc", tokens: Math.ceil(e.size / 4) });
    }
  }
  if (allDocs.length === 0) return { candidates: [] };
  const indexed = allDocs.map(({ doc }) => indexDoc(doc));
  const avgDL = indexed.reduce((sum, d) => sum + d.bodyLen, 0) / allDocs.length || AVG_DOC_LENGTH;
  const N = allDocs.length;
  const dfMap = computeDF(queryTokens, indexed);
  const shortStub = allDocs.map(({ rawContent, source }, i) => source !== "local-doc" && (AUTO_EXTRACTED_RE.test(rawContent) || indexed[i].strippedBody.trim().length < MIN_SUBSTANTIVE_LENGTH));
  const activeSlug = args.projectSlug?.trim().toLowerCase() || "";
  const discCount = discriminativeTerms(queryTokens, dfMap, N).length;
  const scored = allDocs.map(({ doc, rawContent, source, tokens }, i) => {
    const bm25 = scoreBM25(queryTokens, indexed[i], avgDL, N, dfMap);
    const project = (doc.project ?? "").trim().toLowerCase();
    return {
      // Flags for the per-prompt injection gate; never read by ranking. Emitted sparsely below.
      isStub: shortStub[i] || source === "wiki" && STUB_DESCRIPTION_RE.test(doc.description ?? ""),
      isCross: source === "wiki" && activeSlug !== "" && project !== "" && project !== activeSlug,
      path: doc.path,
      tier: 0,
      // SP-1 project-scope tier (0 = scoping inactive); set below, stripped before return
      score: bm25,
      baseScore: bm25,
      // frozen pre-boost BM25 (R2.1): boost math + the floor read THIS, never the mutated score
      grounded: groundedCount(queryTokens, indexed[i], dfMap, N),
      // head-field term overlap; see KnowledgeSearchResult.grounded
      related: doc.related,
      description: doc.aiBlock && Object.keys(doc.aiBlock).length ? aiBlockSnippet(doc.type, doc.aiBlock).slice(0, SNIPPET_CHARS) : source === "local-doc" ? doc.description : doc.description || doc.body.slice(0, SNIPPET_CHARS).replace(/\s+/g, " ").trim(),
      tokens,
      source
    };
  });
  let graphEdges = [];
  try {
    const recs = await loadEdges(join7(knowledgeDir2, "graph", "edges.jsonl"));
    if (recs.length > 0) {
      const nowIso = (/* @__PURE__ */ new Date()).toISOString();
      graphEdges = foldToCurrent(recs).filter((e) => validAt(e, nowIso));
    }
  } catch {
  }
  const GRAPH_RANKING_BOOST = process.env.SB_GRAPH_RANKING_BOOST === "1" || process.env.SB_GRAPH_RANKING_BOOST === "true";
  if (!GRAPH_RANKING_BOOST) {
    for (const s of scored) s.score = s.baseScore;
  } else {
    const GRAPH_BOOST = 0.3;
    const slugScoreMap = new Map(scored.map((s) => [slugFromPath(s.path), s]));
    const boostAccum = /* @__PURE__ */ new Map();
    if (graphEdges.length > 0) {
      const TYPE_W = { requires: 1, affects: 1, part_of: 0.8, supersedes: 0.6, relates: 0.25 };
      const adj = /* @__PURE__ */ new Map();
      for (const e of graphEdges) {
        for (const [a, b] of [[e.from, e.to], [e.to, e.from]]) {
          if (!adj.has(a)) adj.set(a, []);
          adj.get(a).push({ to: b, w: TYPE_W[e.type] ?? 0.25 });
        }
      }
      for (const entry of scored) {
        if (entry.baseScore <= 0) continue;
        const start = slugFromPath(entry.path);
        let frontier = [{ node: start, factor: 1 }];
        const seen = /* @__PURE__ */ new Set([start]);
        for (let hop = 0; hop < 2; hop++) {
          const next = [];
          for (const { node, factor } of frontier) {
            for (const { to, w } of adj.get(node) ?? []) {
              const target = slugScoreMap.get(to);
              if (target && target !== entry) {
                boostAccum.set(to, (boostAccum.get(to) ?? 0) + entry.baseScore * GRAPH_BOOST * factor * w);
              }
              if (!seen.has(to)) {
                seen.add(to);
                next.push({ node: to, factor: factor * GRAPH_BOOST });
              }
            }
          }
          frontier = next;
        }
      }
    } else {
      for (const entry of scored) {
        if (entry.baseScore <= 0) continue;
        for (const rel of entry.related) {
          const target = slugScoreMap.get(rel);
          if (target && target !== entry) {
            boostAccum.set(rel, (boostAccum.get(rel) ?? 0) + entry.baseScore * GRAPH_BOOST);
          }
        }
      }
    }
    for (const s of scored) {
      const b = boostAccum.get(slugFromPath(s.path)) ?? 0;
      s.score = s.baseScore + Math.min(b, s.baseScore);
    }
  }
  const RRF_K = 60;
  let embeddingsActive = false;
  try {
    const docTexts = allDocs.map(({ doc }) => `${doc.title} ${doc.description} ${doc.body}`.slice(0, 512));
    const docPaths = allDocs.map(({ doc }) => doc.path);
    const allTexts = [args.query, ...docTexts];
    const allPaths = ["", ...docPaths];
    const embeddings = await embedTexts(allTexts, wikiRoot, allPaths);
    if (embeddings) {
      embeddingsActive = true;
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
  } catch (e) {
    if (!embedFailLogged) {
      embedFailLogged = true;
      console.error(`knowledge-search: embeddings failed, falling back to BM25: ${e instanceof Error ? e.message : String(e)}`);
    }
  }
  for (let i = 0; i < scored.length; i++) {
    if (shortStub[i]) scored[i].score *= STUB_PENALTY;
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
    scored[i].score *= 1 + RECENCY_BOOST_MAX * Math.min(1, Math.max(0, 1 - daysSince / RECENCY_WINDOW_DAYS));
  }
  const scopeOn = !!args.projectSlug && process.env.SB_PROJECT_SCOPE !== "off" && args.scope !== "all";
  let anchorCount = 0;
  let scopeActive = false;
  if (scopeOn) {
    const slug = args.projectSlug;
    const family = args.brainDir ? projectFamily(args.brainDir, slug) : /* @__PURE__ */ new Set([slug]);
    const projBySlug = new Map(
      allDocs.filter((d) => d.source === "wiki").map((d) => [slugFromPath(d.doc.path), d.doc.project ?? ""])
    );
    const anchors = allDocs.filter((d) => d.source === "wiki" && (d.doc.project ?? "") === slug).map((d) => slugFromPath(d.doc.path));
    anchorCount = anchors.length;
    scopeActive = anchorCount > 0;
    if (scopeActive) {
      const neigh = graphNeighbourhood(anchors, graphEdges, clampEnvInt("SB_SCOPE_HOPS", 2, 0, 4));
      for (const s of scored) {
        if (s.source === "local-doc") {
          s.tier = 1;
          continue;
        }
        const sl = slugFromPath(s.path);
        const proj = projBySlug.get(sl) ?? "";
        s.tier = proj === slug ? 1 : proj !== "" && family.has(proj) ? 2 : neigh.has(sl) ? 3 : proj === "" ? 4 : 5;
      }
    }
  }
  scored.sort((a, b) => scopeActive ? a.tier - b.tier || b.score - a.score : b.score - a.score);
  const topScore = scored.reduce((m, s) => Math.max(m, s.score), 0);
  const topBase = scored.reduce((m, s) => Math.max(m, s.baseScore), 0);
  const passesFloor = (c) => embeddingsActive ? c.score > 0 && (topScore === 0 || c.score >= topScore * MIN_SCORE_RATIO) : c.score > 0 && (topBase === 0 || c.baseScore >= topBase * MIN_SCORE_RATIO);
  let pool = scored;
  if (scopeActive) {
    const inScope = scored.filter((s) => s.tier <= 4);
    const inScopePassing = inScope.filter(passesFloor);
    const enoughInScope = inScopePassing.length >= clampEnvInt("SB_SCOPE_MIN_HITS", 3, 0, 100);
    const slots = clampEnvInt("SB_SCOPE_CROSS_SLOTS", 1, 0, TOP_K);
    const bestInScope = inScopePassing.reduce((m, s) => Math.max(m, s.score), 0);
    const cross = slots > 0 ? scored.filter((s) => s.tier === 5 && passesFloor(s) && s.score > bestInScope).slice(0, slots) : [];
    if (!enoughInScope) {
      const crossSet = new Set(cross);
      pool = cross.length ? [...cross, ...scored.filter((s) => !crossSet.has(s))] : scored;
    } else {
      pool = cross.length ? [...cross, ...inScopePassing] : inScope;
    }
  }
  const returned = pool.filter(passesFloor).slice(0, TOP_K);
  const topFinal = returned.reduce((m, s) => Math.max(m, s.score), 0);
  const candidates = returned.map(({ related, baseScore, tier, isStub, isCross, ...rest }) => ({
    ...rest,
    score_norm: topFinal > 0 ? Math.round(rest.score / topFinal * 1e4) / 1e4 : 0,
    // baseScore surfaces as `relevance`: callers gating on relevance need the frozen
    // pre-boost BM25, not the mode-dependent `score` (see the field doc).
    relevance: Math.round(baseScore * 1e3) / 1e3,
    query_terms: new Set(queryTokens).size,
    discriminative_terms: discCount,
    ...isStub ? { stub: true } : {},
    ...isCross ? { cross_project: true } : {},
    ...scopeActive ? { tier } : {}
  }));
  const accessCounts = await loadAccessCounts(accessFile);
  const ts = (/* @__PURE__ */ new Date()).toISOString();
  for (const c of candidates) {
    if (c.source === "local-doc") continue;
    const slug = slugFromPath(c.path);
    if (!accessCounts[slug]) accessCounts[slug] = { count: 0, last_accessed: "" };
    accessCounts[slug].count++;
    accessCounts[slug].last_accessed = ts;
  }
  await saveAccessCounts(accessCounts, accessFile).catch(() => {
  });
  return {
    candidates,
    ...embeddingsActive ? {} : { degraded: "bm25-only" },
    // Scoping telemetry: anchors=0 with scoping on means tier-1 anchoring collapsed
    // for this slug (see the interface doc for what that can mean).
    ...scopeOn ? { scoped_to: args.projectSlug, anchors: anchorCount } : {}
  };
}
function injectionGroundingNeed(minGrounded2, discriminative, crossProject) {
  if (minGrounded2 <= 0) return 0;
  const base = Math.max(1, Math.min(minGrounded2, discriminative));
  return crossProject ? Math.max(base, Math.min(base + 1, discriminative)) : base;
}
var GATE_ON = /* @__PURE__ */ new Set(["1", "on", "true", "yes"]);
var GATE_OFF = /* @__PURE__ */ new Set(["0", "off", "false", "no"]);
function parseInjectPrecision(raw, warn) {
  const v = (raw ?? "").trim().toLowerCase();
  if (GATE_OFF.has(v)) return false;
  if (v !== "" && !GATE_ON.has(v)) {
    warn(`SB_INJECT_PRECISION=${JSON.stringify(raw)} is not recognised (use off/0/false/no or on/1/true/yes); keeping the precision gate`);
  }
  return true;
}
var injectPrecisionWarning;
var INJECT_PRECISION = parseInjectPrecision(process.env.SB_INJECT_PRECISION, (msg) => {
  injectPrecisionWarning = msg;
  process.stderr.write(`second-brain knowledge-search: ${msg}
`);
});
function injectPrecisionStatus() {
  return { mode: INJECT_PRECISION ? "r1" : "off", ...injectPrecisionWarning ? { warning: injectPrecisionWarning } : {} };
}
async function reportInjectPrecision(brainDir2, script, status = injectPrecisionStatus()) {
  if (status.warning) await appendErrorLog(brainDir2, script, status.warning, 1);
  if (status.mode === "off") await appendGateTrace(brainDir2, script, "gate=inject-precision mode=off");
}
function legacyWikiFilter(candidates, o) {
  const needGrounded = Math.min(o.minGrounded, candidates[0]?.query_terms ?? o.minGrounded);
  return candidates.filter((c) => c.score >= o.minScore && c.relevance >= o.minRelevance && c.grounded >= needGrounded);
}
function injectableWiki(candidates, o) {
  if (!INJECT_PRECISION) return legacyWikiFilter(candidates, o);
  return candidates.filter((c) => !c.stub && c.score >= o.minScore && c.relevance >= o.minRelevance && c.grounded >= injectionGroundingNeed(o.minGrounded, c.discriminative_terms ?? 0, c.cross_project === true));
}
function injectedHitLine(c, platform = process.platform) {
  if (injectDropReason(c, platform)) return "";
  const desc = capCodePoints(foldServedSnippet(stripInvisible(c.description ?? "")).trim(), INJECT_TEXT_MAX_CP);
  const tail = desc ? ` \u2014 ${desc}` : "";
  if (c.source === "local-doc") return `Read ${c.path}${tail}`;
  const slug = foldServedSnippet(stripInvisible(c.path.replace(/^.*[\\/]/, "").replace(/\.md$/, "")));
  return `### [[${slug}]]${tail}`;
}
var INJECT_TEXT_MAX_CP = 200;
var LOCAL_DOC_PATH_MAX_CP = 260;
var LOCAL_DOC_PATH_RE = /^[\p{L}\p{N} ._\-/\\:~+@,()'&#]+$/u;
var HANGUL_FILLER_RE = new RegExp(`[${String.fromCodePoint(4447)}${String.fromCodePoint(4448)}]`, "u");
function capCodePoints(s, max) {
  const cps2 = [...s];
  return cps2.length <= max ? s : `${cps2.slice(0, max - 1).join("").trimEnd()}\u2026`;
}
function injectDropReason(c, platform = process.platform) {
  if (c.source !== "local-doc") return "";
  const p = c.path;
  if (!isPlainAbsolutePath(p, platform)) {
    return p.split(/[\\/]/).some((seg) => seg === "." || seg === "..") ? "path-dots" : "path-relative";
  }
  if (p.includes(" \u2014 ")) return "path-separator";
  if ([...p].length > LOCAL_DOC_PATH_MAX_CP) return "path-length";
  if (p.normalize("NFKC") !== p) return "path-not-nfkc";
  if (!LOCAL_DOC_PATH_RE.test(p) || HANGUL_FILLER_RE.test(p)) return "path-chars";
  if (foldServedSnippet(p) !== p) return "path-frame-text";
  return "";
}
function injectedHitLines(candidates, max, platform = process.platform) {
  const lines = [];
  const drops = [];
  for (const c of candidates) {
    if (lines.length >= max) break;
    const reason = injectDropReason(c, platform);
    if (reason) {
      drops.push({ path: c.path, source: c.source, reason });
      continue;
    }
    lines.push(injectedHitLine(c, platform));
  }
  return { lines, drops };
}
async function reportInjectDrops(brainDir2, script, drops) {
  for (const d of drops) {
    await appendGateTrace(
      brainDir2,
      script,
      `gate=inject-drop reason=${d.reason} source=${d.source} path=${JSON.stringify(capCodePoints(d.path, 300))}`
    );
  }
}
function toCounts(s) {
  const toks = tokenize(s);
  const counts = /* @__PURE__ */ new Map();
  for (const t of toks) counts.set(t, (counts.get(t) ?? 0) + 1);
  return { counts, len: toks.length };
}
function indexDoc(doc) {
  const strippedBody = stripAiBlock(doc.body);
  const fields = [
    { text: doc.title, weight: 3 },
    { text: doc.description, weight: 2 },
    { text: doc.tags.join(" "), weight: 2 },
    { text: aiBlockText(doc), weight: 1.5 },
    // proposition-level shared intermediate
    { text: strippedBody, weight: 1 }
    // prose body (block excluded → no double-count)
  ].map(({ text, weight }) => ({ ...toCounts(text), weight }));
  const terms = /* @__PURE__ */ new Set();
  for (const f of fields) for (const t of f.counts.keys()) terms.add(t);
  return { fields, terms, strippedBody, bodyLen: fields[4].len };
}
function groundedCount(queryTokens, idx, dfMap, N) {
  const head = idx.fields.slice(0, 3);
  let n = 0;
  for (const t of discriminativeTerms(queryTokens, dfMap, N)) {
    if (head.some((f) => f.counts.has(t))) n++;
  }
  return n;
}
function discriminativeTerms(queryTokens, dfMap, N) {
  const distinct = [...new Set(queryTokens)].filter(INJECT_PRECISION ? (t) => !GROUNDING_STOPWORDS.has(t) && !SINGLE_LETTER_RE.test(t) && !PURE_DIGITS_RE.test(t) : (t) => !LEGACY_GROUNDING_STOPWORDS.has(t));
  if (N < MIN_CORPUS_FOR_DF) return distinct;
  const maxDf = Math.max(2, N * COMMON_TERM_DF_SHARE);
  return distinct.filter((t) => (dfMap.get(t) ?? 0) <= maxDf);
}
function computeDF(queryTokens, docs) {
  const dfMap = /* @__PURE__ */ new Map();
  for (const qt of queryTokens) {
    if (isDateToken(qt)) continue;
    let df = 0;
    for (const d of docs) if (d.terms.has(qt)) df++;
    dfMap.set(qt, df);
  }
  return dfMap;
}
function scoreBM25(queryTokens, doc, avgDL, N, dfMap) {
  let score = 0;
  for (const qt of queryTokens) {
    if (isDateToken(qt)) continue;
    const df = dfMap.get(qt) ?? 0;
    const idf = Math.log((N - df + 0.5) / (df + 0.5) + 1);
    for (const field of doc.fields) {
      const tf = field.counts.get(qt) ?? 0;
      if (tf === 0) continue;
      const dl = field.len || 1;
      const tfNorm = tf * (BM25_K1 + 1) / (tf + BM25_K1 * (1 - BM25_B + BM25_B * dl / avgDL));
      score += idf * tfNorm * field.weight;
    }
  }
  return Math.round(score * 100) / 100;
}
function tokenize(s) {
  return s.toLowerCase().match(/[a-z0-9]+/g) ?? [];
}
function isDateToken(t) {
  return DATE_TOKEN_RE.test(t);
}
function slugFromPath(p) {
  return p.replace(/^.*[\\/]/, "").replace(/\.md$/, "");
}

// src/tools/context-serve-cli.ts
var query = process.argv[2] || "";
if (!query) {
  process.exit(0);
}
var SEP = "--8<--SB-EPISODIC--8<--";
var knowledgeDir = resolveKnowledgeDir();
var minScore = parseFloat(process.env.KNOWLEDGE_MIN_SCORE || "0");
var minRelevance = envNum("SB_INJECT_MIN_RELEVANCE", 0, 0, Number.MAX_SAFE_INTEGER);
var minGrounded = envNum("SB_INJECT_MIN_GROUNDED", 2, 0, 64);
var brainDir = resolveBrainDir();
var projectSlug = process.env.SB_ACTIVE_SLUG?.trim() || void 0;
await reportInjectPrecision(brainDir, "context-serve-cli");
var failedOpen = (section, e) => appendErrorLog(
  brainDir,
  "context-serve-cli",
  `${section} section failed open (empty): ${e instanceof Error ? e.message : String(e)}`,
  1
);
var wikiLines = [];
try {
  const result = await knowledgeSearch({ query, knowledgeDir, brainDir, projectSlug });
  const { lines, drops } = injectedHitLines(injectableWiki(result.candidates, { minScore, minRelevance, minGrounded }), 2);
  wikiLines.push(...lines);
  await reportInjectDrops(brainDir, "context-serve-cli", drops);
} catch (e) {
  await failedOpen("wiki", e);
}
var sessionId = process.env.SB_SESSION_ID?.trim() || "";
var epiLines = [];
try {
  if (!brainDir) throw new Error("no brain dir resolvable");
  epiLines = await serveEpisodicLines(query, brainDir, { sessionId, activeProject: projectSlug });
} catch (e) {
  await failedOpen("episodic", e);
}
if (wikiLines.length === 0 && epiLines.length === 0) {
  process.exit(0);
}
for (const l of wikiLines) console.log(l);
console.log(SEP);
for (const l of epiLines) console.log(l);
