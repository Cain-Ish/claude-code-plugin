// src/cli/sb.ts
import { promises as fs13, constants as fsConstants } from "fs";
import { join as join12, delimiter as pathDelimiter } from "path";
import { execFile as execFile2 } from "child_process";

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
var RENAME_RETRY = /* @__PURE__ */ new Set(["EPERM", "EACCES", "EBUSY"]);
var RENAME_BACKOFF_MS = [10, 20, 40, 80, 160, 200, 200, 200, 200, 200, 200];
var realIo = {
  writeFile: (f, d) => fs.writeFile(f, d, "utf-8"),
  rename: (a, b) => fs.rename(a, b),
  rm: (f) => fs.rm(f, { force: true }),
  sleep: (ms) => new Promise((r) => setTimeout(r, ms))
};
async function writeFileAtomic(file, data, io = realIo) {
  const tmp = uniqueTmp(file);
  try {
    await io.writeFile(tmp, data);
    for (let i = 0; ; i++) {
      try {
        await io.rename(tmp, file);
        return;
      } catch (e) {
        if (!RENAME_RETRY.has(e.code ?? "")) throw e;
        if (i >= RENAME_BACKOFF_MS.length) break;
        await io.sleep(RENAME_BACKOFF_MS[i]);
      }
    }
    await io.writeFile(file, data);
    await io.rm(tmp).catch((e) => console.error(
      `writeFileAtomic: ${file} written in place; leftover ${tmp} not removed: ${e instanceof Error ? e.message : String(e)}`
    ));
  } catch (e) {
    await io.rm(tmp).catch(() => {
    });
    throw e;
  }
}

// src/tools/knowledge-search.ts
import { join as join7 } from "path";

// src/brain-paths.ts
import { join, isAbsolute as isAbsolute2 } from "path";
import { homedir } from "os";
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
function dotDequantized(query, v, es) {
  let dot = 0;
  const n = Math.min(query.length, v.length);
  for (let i = 0; i < n; i++) dot += query[i] * v[i];
  return dot * es;
}
function embeddingSimilarity(query, row) {
  return dotDequantized(query, decodeE8(row.e8), row.es);
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
function displaySnippet(r, max) {
  const text = r.userSnippet.trim() ? r.userSnippet : `[machine turn]${r.assistantSnippet ? " " + r.assistantSnippet : ""}`;
  return max === void 0 ? text : text.slice(0, max);
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
async function episodicSearch(args, brainDir2) {
  const { index } = await loadIndex(brainDir2);
  if (index.exchanges.length === 0) return { results: [] };
  const limit = Math.min(args.limit ?? DEFAULT_LIMIT, MAX_LIMIT);
  const query = args.query;
  if (Array.isArray(query)) {
    return multiConceptSearch(query, index, limit, args, brainDir2);
  }
  const mode = args.mode ?? "both";
  const candLimit = args.activeProject && !args.project ? Math.max(limit * 5, 25) : limit * 2;
  let vectorResults = [];
  let textResults = [];
  let degraded;
  if (mode === "vector" || mode === "both") {
    const v = await vectorSearch(query, index, candLimit, args, brainDir2);
    vectorResults = v.hits;
    if (v.unavailable) degraded = mode === "both" ? "text-only" : "vector-unavailable";
  }
  if (mode === "text" || mode === "both") {
    textResults = textSearch(query, index, candLimit, args);
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
async function vectorSearch(query, index, limit, filters, brainDir2) {
  const filtered = applyFilters(index.exchanges, filters);
  const withEmbeddings = filtered.filter(hasVector);
  if (withEmbeddings.length === 0) return { hits: [], unavailable: filtered.length > 0 };
  const queryEmbedding = await embedTexts(
    [query],
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
function textSearch(query, index, limit, filters) {
  const filtered = applyFilters(index.exchanges, filters);
  const tokens = query.toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length >= 2);
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
  if (filters.excludeSessionId) {
    const sid = filters.excludeSessionId;
    result2 = result2.filter((e) => e.sessionId !== sid);
  }
  if (filters.requireUserText) {
    result2 = result2.filter((e) => cleanUserText(e.userSnippet).trim() !== "");
  }
  return result2;
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
var HANGUL_FILLER_RE = new RegExp(`[${String.fromCodePoint(4447)}${String.fromCodePoint(4448)}]`, "u");
function capCodePoints(s, max) {
  const cps2 = [...s];
  return cps2.length <= max ? s : `${cps2.slice(0, max - 1).join("").trimEnd()}\u2026`;
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

// src/tools/pin-to-user.ts
import { promises as fs9 } from "fs";
import { join as join9 } from "path";

// src/tools/hot-file-lock.ts
import { promises as fs8 } from "fs";
import { randomInt } from "crypto";
import { basename as basename2, dirname, join as join8 } from "path";
var STALE_MS = 6e4;
var HUNG_MS = 6e5;
var LOCK_WAIT_MS = 15e3;
function lockPathFor(file) {
  return join8(dirname(file), `.${basename2(file)}.lock`);
}
var sleep = (ms) => new Promise((r) => setTimeout(r, ms));
var firstLine = async (f) => (await fs8.readFile(f, "utf-8")).split(/\r?\n/)[0];
function holderGone(token) {
  const pid = token.split(".")[0];
  if (!/^\d+$/.test(pid)) return true;
  if (process.platform === "win32") return true;
  try {
    process.kill(Number(pid), 0);
    return false;
  } catch (e) {
    return e.code === "ESRCH";
  }
}
async function stealIfStale(lf) {
  let age, holder;
  try {
    age = Date.now() - (await fs8.stat(lf)).mtimeMs;
    holder = await firstLine(lf);
  } catch {
    return;
  }
  if (age <= STALE_MS || age <= HUNG_MS && !holderGone(holder)) return;
  const grab = join8(dirname(lf), `.steal-${process.pid}-${randomInt(1e9)}${basename2(lf)}`);
  try {
    await fs8.rename(lf, grab);
  } catch {
    return;
  }
  const got = await firstLine(grab).catch(() => "");
  if (got !== holder) {
    await fs8.writeFile(lf, `${got}
`, { flag: "wx" }).catch(() => console.error(`[hot-file-lock] took a fresh lock by mistake (holder ${got}) on ${lf} and could not put it back; two writers may overlap`));
  } else {
    console.error(`[hot-file-lock] stealing a stale lock (${Math.round(age / 1e3)} s old, holder ${holder || "?"}) on ${lf}`);
  }
  await fs8.rm(grab, { force: true });
}
var LOCK_STOLEN = "lock stolen while held; nothing written, retry";
async function withFileLock(file, busy, fn, waitMs = LOCK_WAIT_MS) {
  const lf = lockPathFor(file);
  const token = `${process.pid}.${randomInt(1e9)}`;
  const end = Date.now() + waitMs;
  let lastCode = "EEXIST", noLock = 0;
  for (; ; ) {
    try {
      await fs8.writeFile(lf, `${token}
`, { flag: "wx" });
      break;
    } catch (e) {
      lastCode = e.code ?? String(e);
      if (lastCode !== "EEXIST" && lastCode !== "EPERM" && lastCode !== "EACCES") throw e;
    }
    noLock = lastCode === "EEXIST" ? 0 : await fs8.stat(lf).then(() => 0, (s) => s.code === "ENOENT" ? noLock + 1 : 0);
    if (noLock >= 3) throw new Error(`cannot create ${lf} (${lastCode}, no lock present; directory unwritable?); ${basename2(file)} not written`);
    await stealIfStale(lf);
    if (Date.now() >= end) {
      const holder = await firstLine(lf).catch(() => "none");
      return busy(`${basename2(file)} lock not taken within ${Math.round(waitMs / 1e3)} s (${lastCode}, holder ${holder}); nothing written, retry`);
    }
    await sleep(100);
  }
  try {
    return await fn(async () => await firstLine(lf).catch(() => "") === token);
  } finally {
    const held = await firstLine(lf).catch(() => "");
    if (held === token) {
      await fs8.rm(lf, { force: true }).catch((e) => console.error(`[hot-file-lock] could not remove the lock on ${basename2(file)}: ${e.message}; it goes stale in ${STALE_MS / 1e3} s`));
    } else console.error(`[hot-file-lock] the lock on ${basename2(file)} is no longer ours (ours ${token}, now ${held || "none"}: stolen while held); left as it is`);
  }
}

// src/tools/pin-to-user.ts
var MAX_PINS = 15;
var PIN_RE = /^- \[\d{4}-\d{2}-\d{2}\]\s+(.*)$/;
var PIN_SECTION = "## Pinned";
var PIN_TEXT_CAP = 400;
function flattenField(s, cap) {
  return s.normalize("NFC").replace(/[\r\n`]/g, " ").replace(/\s+/g, " ").trim().slice(0, cap);
}
async function pinToUser(args) {
  const dir = resolveBrainDir(args.brainDir);
  const file = join9(dir, "USER.md");
  const date = (/* @__PURE__ */ new Date()).toISOString().slice(0, 10);
  const trimmed = flattenField(args.text, PIN_TEXT_CAP);
  if (!trimmed) {
    return { ok: false, line_added: "", reason: "empty text after sanitization" };
  }
  const newLine = `- [${date}] ${trimmed}`;
  await fs9.mkdir(dir, { recursive: true });
  return withFileLock(
    file,
    (reason) => ({ ok: false, line_added: "", reason }),
    (owned) => pinUserLocked(file, trimmed, newLine, owned)
  );
}
async function pinUserLocked(file, trimmed, newLine, owned) {
  let content = "";
  try {
    content = await fs9.readFile(file, "utf-8");
  } catch (e) {
    const code = e.code;
    if (code !== "ENOENT") return { ok: false, line_added: "", reason: `cannot read USER.md (${code ?? String(e)}); nothing written` };
    content = `# USER preferences

${PIN_SECTION}
`;
  }
  const lines = content.split("\n");
  const pinLines = lines.filter((l) => PIN_RE.test(l));
  const existing = pinLines.find((l) => l.match(PIN_RE)[1].trim() === trimmed);
  if (existing !== void 0) {
    return { ok: true, line_added: existing, reason: "already present" };
  }
  if (pinLines.length >= MAX_PINS) {
    return { ok: false, line_added: "", reason: `would exceed ${MAX_PINS} pinned lines (hand-written sections do not count)` };
  }
  const out = [...lines];
  let secIdx = out.findIndex((l) => l.trim() === PIN_SECTION);
  if (secIdx === -1) {
    if (out.length && out[out.length - 1] !== "") out.push("");
    out.push(PIN_SECTION);
    secIdx = out.length - 1;
  }
  let insertAt = secIdx + 1;
  for (let i = secIdx + 1; i < out.length; i++) {
    if (/^## /.test(out[i])) break;
    if (PIN_RE.test(out[i])) insertAt = i + 1;
  }
  out.splice(insertAt, 0, newLine);
  const projected = out.join("\n").replace(/\n*$/, "\n");
  if (!await owned()) return { ok: false, line_added: "", reason: LOCK_STOLEN };
  await writeFileAtomic(file, projected);
  return { ok: true, line_added: newLine };
}

// src/tools/pin-to-project.ts
import { promises as fs10 } from "fs";
var SECTION_HEADER = { blockers: "## Open blockers", decisions: "## Recent decisions", conventions: "## Conventions" };
var ENTRY_PREFIX = { blockers: "- [active] ", decisions: "- [decision] ", conventions: "- " };
function flattenField2(s, cap) {
  if (!s) return "";
  return s.normalize("NFC").replace(/[\r\n`]/g, " ").replace(/\s+/g, " ").trim().slice(0, cap);
}
var SUPERSEDES_MIN_NEEDLE = 8;
function bulletCore(line) {
  let s = line.normalize("NFC").replace(/^- /, "");
  let prev;
  do {
    prev = s;
    s = s.replace(/^\[\d{4}-\d{2}-\d{2}\] /, "").replace(/^\[(active|resolved|stale|decision|pinned|superseded)\] /, "");
  } while (s !== prev);
  return s.replace(/ \(why: .*\)$/, "").trim();
}
async function pinToProject(args) {
  if (!(args.section in SECTION_HEADER)) {
    return { ok: false, line_added: "", project_slug: args.slug, reason: "unknown section" };
  }
  try {
    validateSlug(args.slug);
  } catch (e) {
    if (e instanceof PathGuardError) {
      return { ok: false, line_added: "", project_slug: args.slug, reason: `invalid slug: ${e.message}` };
    }
    throw e;
  }
  const dir = resolveBrainDir(args.brainDir);
  let file;
  try {
    file = assertWithin(dir, "projects", args.slug, "PROJECT.md");
  } catch (e) {
    if (e instanceof PathGuardError) {
      return { ok: false, line_added: "", project_slug: args.slug, reason: `path traversal blocked: ${e.message}` };
    }
    throw e;
  }
  const noFile = await fs10.access(file).then(() => "", (e) => e.code ?? String(e));
  if (noFile) return { ok: false, line_added: "", project_slug: args.slug, reason: `no PROJECT.md for ${args.slug} (${noFile})` };
  return withFileLock(
    file,
    (reason) => ({ ok: false, line_added: "", project_slug: args.slug, reason }),
    (owned) => pinLocked(args, file, owned)
  );
}
async function pinLocked(args, file, owned) {
  const stolen = { ok: false, line_added: "", project_slug: args.slug, reason: LOCK_STOLEN };
  const content = await fs10.readFile(file, "utf-8");
  const sectionHeader = SECTION_HEADER[args.section];
  const trimmed = flattenField2(args.text, 400);
  if (!trimmed) {
    return { ok: false, line_added: "", project_slug: args.slug, reason: "empty text after sanitization" };
  }
  let newEntry;
  if (args.section === "decisions") {
    const date = (/* @__PURE__ */ new Date()).toISOString().slice(0, 10);
    let suffix = "";
    const why = flattenField2(args.reasoning, 200);
    const rej = flattenField2(args.rejected, 200);
    if (why && rej) suffix = ` (why: ${why}; rejected: ${rej})`;
    else if (why) suffix = ` (why: ${why})`;
    else if (rej) suffix = ` (why: unstated; rejected: ${rej})`;
    newEntry = `- [${date}] [decision] ${trimmed}${suffix}`;
  } else {
    newEntry = `${ENTRY_PREFIX[args.section]}${trimmed}`;
  }
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
  const newCore = trimmed.replace(/ \(why: .*\)$/, "").trim();
  let reason;
  let marked = false;
  const supersedesRequested = !!flattenField2(args.supersedes, 200);
  const needle = flattenField2(args.supersedes, 200).toLowerCase();
  if (supersedesRequested && args.section !== "decisions") {
    reason = "supersedes is decisions-only \u2014 ignored for this section";
  } else if (args.section === "decisions" && needle) {
    if (needle.length < SUPERSEDES_MIN_NEEDLE) {
      reason = `supersedes needle too short (<${SUPERSEDES_MIN_NEEDLE} chars) \u2014 nothing marked`;
    } else {
      for (let i = idx + 1; i < endIdx; i++) {
        if (!lines[i].startsWith("- ") || lines[i].startsWith("- [superseded] ")) continue;
        const core = bulletCore(lines[i]);
        if (core === newCore) continue;
        if (core.toLowerCase().includes(needle)) {
          lines[i] = `- [superseded] ${lines[i].slice(2)}`;
          marked = true;
          break;
        }
      }
      if (!marked) reason = "supersedes target not found";
    }
  }
  for (let i = idx + 1; i < endIdx; i++) {
    if (!lines[i].startsWith("- ")) continue;
    if (lines[i].startsWith("- [superseded] ") || lines[i].startsWith("- [stale] ")) continue;
    if (bulletCore(lines[i]) === newCore) {
      if (marked) {
        if (!await owned()) return stolen;
        await writeFileAtomic(file, lines.join("\n"));
      }
      const dup = { ok: true, line_added: lines[i], project_slug: args.slug, reason: "already present" };
      if (supersedesRequested) dup.superseded = marked;
      return dup;
    }
  }
  lines.splice(endIdx, 0, newEntry);
  if (!await owned()) return stolen;
  await writeFileAtomic(file, lines.join("\n"));
  const res = { ok: true, line_added: newEntry, project_slug: args.slug };
  if (reason) res.reason = reason;
  if (supersedesRequested) res.superseded = marked;
  return res;
}

// src/tools/raw-inbox.ts
import { promises as fs11 } from "fs";
import { join as join10, basename as basename3, extname } from "path";

// src/tools/minhash.ts
var NUM_HASHES = 128;
var A = new Uint32Array(NUM_HASHES);
var B = new Uint32Array(NUM_HASHES);
{
  let seed = 2654435761 >>> 0;
  const nextRand = () => {
    seed = Math.imul(seed, 1664525) + 1013904223 >>> 0;
    return seed;
  };
  for (let i = 0; i < NUM_HASHES; i++) {
    A[i] = (nextRand() | 1) >>> 0;
    B[i] = nextRand() >>> 0;
  }
}

// src/tools/raw-inbox.ts
function rawDir(brainDir2, slug) {
  return join10(brainDir2, "projects", slug, "raw");
}
function parse2(content, id) {
  const m = matchFrontmatter(content);
  const base = {
    id,
    source: "",
    captured_at: "",
    captured_by: "user",
    content_type: "",
    status: "unprocessed",
    hash: "",
    gist: "",
    body: ""
  };
  if (!m) {
    return { ...base, body: content, malformed: true };
  }
  const { fm: fmText, body } = m;
  const get = (k) => {
    const mm = fmText.match(new RegExp(`^${k}:[ \\t]*(.*)$`, "m"));
    return mm ? mm[1].trim() : void 0;
  };
  const status = get("status") ?? "";
  const validStatus = status === "unprocessed" || status === "processed" || status === "discarded";
  const item = {
    id,
    // Sanitize on READ too, so items written before the sanitizer shipped (or by any
    // non-serialize path) are cleaned on the way to the drainer/wiki, not just on write.
    source: stripInvisible(get("source") ?? ""),
    captured_at: get("captured_at") ?? "",
    captured_by: get("captured_by") ?? "user",
    origin: get("origin") || void 0,
    content_type: get("content_type") ?? "",
    status: validStatus ? status : "unprocessed",
    target_node: get("target_node") || void 0,
    blob: get("blob") || void 0,
    hash: get("hash") ?? "",
    gist: stripInvisible(get("gist") ?? ""),
    body: stripInvisible(body.trim())
  };
  if (!item.source || !item.captured_at || !item.content_type || !validStatus) item.malformed = true;
  return item;
}
async function readItems(brainDir2, slug) {
  const dir = rawDir(brainDir2, slug);
  let names = [];
  try {
    names = (await fs11.readdir(dir)).filter((n) => n.endsWith(".md"));
  } catch {
    return [];
  }
  const items = [];
  for (const name of names.sort()) {
    try {
      const content = await fs11.readFile(join10(dir, name), "utf-8");
      items.push(parse2(content, name.replace(/\.md$/, "")));
    } catch {
    }
  }
  return items;
}
async function unprocessedCount(brainDir2, slug) {
  assertSafeSlug(slug);
  const items = await readItems(brainDir2, slug);
  return items.filter((i) => i.status === "unprocessed" || i.malformed).length;
}

// src/tools/dream.ts
import { existsSync as existsSync2 } from "fs";
import { execFile } from "child_process";
import { promisify } from "util";
var exec = promisify(execFile);
function toBashPath(p) {
  let s = cleanEnvPath(p).replace(/\\/g, "/");
  const drive = s.match(/^([A-Za-z]):\//);
  if (drive) s = "/" + drive[1].toLowerCase() + s.slice(2);
  return s;
}
function resolveBashExePure(platform, exists, env) {
  if (platform !== "win32") return "bash";
  const pf = env["PROGRAMFILES"] ?? "C:\\Program Files";
  const localAppData = env["LOCALAPPDATA"] ?? "";
  const candidates = [
    `${pf}\\Git\\bin\\bash.exe`,
    "C:\\Program Files (x86)\\Git\\bin\\bash.exe",
    ...localAppData ? [`${localAppData}\\Programs\\Git\\bin\\bash.exe`] : []
  ];
  for (const c of candidates) {
    if (exists(c)) return c;
  }
  return "bash";
}
function resolveBashExe() {
  return resolveBashExePure(process.platform, existsSync2, process.env);
}

// src/tools/buddy-config.ts
import { promises as fs12 } from "fs";
import { join as join11, dirname as dirname2 } from "path";
import { homedir as homedir3 } from "os";
var DEFAULT_NAME = "Kapi";
var isObj = (v) => !!v && typeof v === "object" && !Array.isArray(v);
var errCode = (e) => e?.code;
function renderCard(name) {
  const ascii = process.env.SB_BUDDY_ASCII === "on";
  const dotB = ascii ? "O" : "\u25CB";
  const TL = ascii ? "+" : "\u256D", TR = ascii ? "+" : "\u256E", BL = ascii ? "+" : "\u2570", BR = ascii ? "+" : "\u256F";
  const H = ascii ? "-" : "\u2500", V = ascii ? "|" : "\u2502";
  const rule = H.repeat(name.length + 2);
  return ["\u{1F9E0}", " o", `  ${dotB} ${TL}${rule}${TR}`, `    ${V} ${name} ${V}`, `    ${BL}${rule}${BR}`].join("\n");
}
async function readConfigStrict(brainDir2) {
  const file = join11(brainDir2, "buddy.json");
  let raw;
  try {
    raw = await fs12.readFile(file, "utf-8");
  } catch (e) {
    if (errCode(e) === "ENOENT") return {};
    throw new Error(`cannot read ${file} (${errCode(e) ?? e})`);
  }
  if (!raw.trim()) return {};
  let j;
  try {
    j = JSON.parse(raw);
  } catch {
    throw new Error(`${file} is not valid JSON \u2014 fix or delete it, then re-run`);
  }
  if (!isObj(j)) throw new Error(`${file} is not a JSON object \u2014 fix or delete it, then re-run`);
  return j;
}
async function readConfig(brainDir2) {
  try {
    return await readConfigStrict(brainDir2);
  } catch {
    return {};
  }
}
async function patchConfig(brainDir2, patch) {
  const cfg = await readConfigStrict(brainDir2);
  for (const [k, v] of Object.entries(patch)) {
    if (v === null) delete cfg[k];
    else cfg[k] = v;
  }
  await fs12.mkdir(brainDir2, { recursive: true });
  const file = join11(brainDir2, "buddy.json");
  const tmp = `${file}.tmp.${process.pid}`;
  try {
    await fs12.writeFile(tmp, JSON.stringify(cfg, null, 2) + "\n", "utf-8");
    await fs12.rename(tmp, file);
  } catch (e) {
    await fs12.rm(tmp, { force: true }).catch(() => void 0);
    throw e;
  }
  return cfg;
}
var UNPRINTABLE = /[\p{Cc}\p{Cf}\u2028\u2029]/u;
function validName(name) {
  return name.length >= 1 && name.length <= 14 && !UNPRINTABLE.test(name);
}
function buddyName(cfg) {
  const n = typeof cfg.name === "string" ? cfg.name.trim().slice(0, 14) : "";
  return n && validName(n) ? n : DEFAULT_NAME;
}
async function dropStaleIdentity(brainDir2) {
  if (!("identity" in await readConfig(brainDir2))) return false;
  await patchConfig(brainDir2, { identity: null });
  return true;
}
function claudeConfigDir() {
  return cleanEnvPath(process.env.CLAUDE_CONFIG_DIR) || join11(homedir3(), ".claude");
}
function settingsPath() {
  return join11(claudeConfigDir(), "settings.json");
}
var posix = (p) => p.replace(/\\/g, "/");
var shq = (s) => `'${s.replace(/'/g, `'\\''`)}'`;
var unshq = (s) => s.replace(/'\\''/g, `'`);
function shimPath(brainDir2) {
  return join11(brainDir2, "bin", "buddy-statusline.sh");
}
function statuslineCommand(brainDir2, chain) {
  return `SB_BUDDY_CHAIN=${shq(chain ?? "")} bash ${shq(posix(shimPath(brainDir2)))}`;
}
function parseOurCommand(command) {
  const m = /^(?:SB_BUDDY_CHAIN='((?:[^']|'\\'')*)' )?bash (?:"([^"$`\\]*)"|'((?:[^']|'\\'')*)')$/.exec(command);
  if (!m) return null;
  const path = m[2] ?? unshq(m[3] ?? "");
  if (!/[\\/]buddy-statusline\.sh$/.test(path)) return null;
  return { chain: m[1] ? unshq(m[1]) : null };
}
function cacheBaseOf(pluginRoot) {
  const m = /^(.*[\\/]plugins[\\/]cache[\\/][^\\/]+[\\/]second-brain)[\\/][^\\/]+[\\/]?$/.exec(pluginRoot);
  return m ? m[1] : null;
}
function shimBody(devRoot, cacheBase) {
  const glob = cacheBase ? `${shq(posix(cacheBase))}/*` : `"$_cfg"/plugins/cache/*/second-brain/*`;
  return `#!/bin/bash
# buddy-statusline shim \u2014 generated by \`sb buddy install\` (do not hand-edit). Stable path that
# survives plugin upgrades: resolves the newest installed second-brain version's renderer and
# sources it with this process's stdin (the statusline JSON) and env (SB_BUDDY_CHAIN, COLUMNS).
set -u
_r=""; _rk=-1; _dev=${devRoot ? shq(posix(devRoot)) : "''"}
_cfg="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; _cfg="\${_cfg//\\\\//}"   # C:\\x \u2192 C:/x: a backslash path never globs
if [ -n "$_dev" ] && [ -f "$_dev/scripts/buddy-statusline.sh" ]; then _r="$_dev/scripts/buddy-statusline.sh"
else
  for _d in ${glob}; do
    [[ "\${_d##*/}" =~ ^([0-9]+)\\.([0-9]+)\\.([0-9]+)$ ]] && [ -f "$_d/scripts/buddy-statusline.sh" ] || continue
    _k=$(( 10#\${BASH_REMATCH[1]} * 1000000 + 10#\${BASH_REMATCH[2]} * 1000 + 10#\${BASH_REMATCH[3]} ))
    [ "$_k" -gt "$_rk" ] && { _rk=$_k; _r="$_d/scripts/buddy-statusline.sh"; }
  done
fi
# fail loud, not blank: a pruned or renamed marketplace would otherwise just make the buddy vanish
[ -n "$_r" ] || { printf 'buddy: no second-brain renderer found \u2014 run /second-brain:buddy install\\n'; exit 0; }
. "$_r"
`;
}
var REFRESH_S = 1;
async function readSettings(file) {
  let raw;
  try {
    raw = await fs12.readFile(file, "utf-8");
  } catch (e) {
    if (errCode(e) === "ENOENT") return { raw: "", settings: {} };
    throw new Error(`cannot read ${file} (${errCode(e) ?? e}) \u2014 nothing changed`);
  }
  if (!raw.trim()) return { raw, settings: {} };
  const j = JSON.parse(raw);
  if (!isObj(j)) throw new Error(`${file} is not a JSON object`);
  return { raw, settings: j };
}
async function writeSettings(file, settings, expectedRaw) {
  let target = file;
  let mode;
  try {
    target = await fs12.realpath(file);
    mode = (await fs12.stat(target)).mode & 511;
  } catch (e) {
    if (errCode(e) !== "ENOENT") throw e;
  }
  await fs12.mkdir(dirname2(target), { recursive: true });
  const tmp = `${target}.tmp.${process.pid}`;
  try {
    await fs12.writeFile(tmp, JSON.stringify(settings, null, 2) + "\n", { encoding: "utf-8", mode: mode ?? 438 });
    if (mode !== void 0) await fs12.chmod(tmp, mode);
    let now = "";
    try {
      now = await fs12.readFile(target, "utf-8");
    } catch (e) {
      if (errCode(e) !== "ENOENT") throw e;
    }
    if (now !== expectedRaw) throw new Error(`${file} changed while sb buddy was editing it \u2014 nothing written; re-run`);
    await fs12.rename(tmp, target);
  } catch (e) {
    await fs12.rm(tmp, { force: true }).catch(() => void 0);
    throw e;
  }
}
async function backupSettings(file, raw) {
  const backup = `${file}.bak-${(/* @__PURE__ */ new Date()).toISOString().replace(/[:.]/g, "-")}`;
  await fs12.writeFile(backup, raw, { encoding: "utf-8", mode: 384 });
  await fs12.chmod(backup, 384);
  return backup;
}
async function installStatusline(brainDir2, pluginRoot) {
  const file = settingsPath();
  const { raw, settings } = await readSettings(file);
  await readConfigStrict(brainDir2);
  const prev = isObj(settings.statusLine) ? settings.statusLine : void 0;
  const prevCmd = prev && prev.type === "command" && typeof prev.command === "string" ? prev.command : "";
  const parsed = prevCmd ? parseOurCommand(prevCmd) : null;
  if (!parsed && prevCmd.includes("buddy-statusline")) {
    throw new Error(`${file} statusLine runs buddy-statusline but is not the form sb buddy writes (hand-edited?) \u2014 fix or remove it, then re-run`);
  }
  const cacheBase = cacheBaseOf(pluginRoot);
  const shim = shimPath(brainDir2);
  await fs12.mkdir(join11(brainDir2, "bin"), { recursive: true });
  await fs12.writeFile(shim, shimBody(cacheBase ? null : pluginRoot, cacheBase), { encoding: "utf-8", mode: 493 });
  const chained = parsed ? parsed.chain : prevCmd || null;
  const command = statuslineCommand(brainDir2, chained);
  const keep = parsed && typeof prev?.refreshInterval === "number" && prev.refreshInterval >= 1;
  const consent = { react: true, chain: null, identity: null };
  if (parsed && prevCmd === command && keep) {
    await patchConfig(brainDir2, consent);
    return { settings: file, backup: null, chained, command, shim, changed: false };
  }
  const backup = raw.trim() ? await backupSettings(file, raw) : null;
  settings.statusLine = { ...prev ?? {}, type: "command", command, refreshInterval: keep ? prev.refreshInterval : REFRESH_S };
  await writeSettings(file, settings, raw);
  await patchConfig(brainDir2, parsed ? consent : { ...consent, prev_statusline: prev ?? null });
  return { settings: file, backup, chained, command, shim, changed: true };
}
async function uninstallStatusline(brainDir2) {
  const file = settingsPath();
  const { raw, settings } = await readSettings(file);
  const cfg = await readConfigStrict(brainDir2);
  const cur = isObj(settings.statusLine) ? settings.statusLine : void 0;
  const curCmd = cur && typeof cur.command === "string" ? cur.command : "";
  const parsed = curCmd ? parseOurCommand(curCmd) : null;
  if (!parsed && curCmd.includes("buddy-statusline")) {
    throw new Error(`${file} statusLine runs buddy-statusline but is not the form sb buddy writes (hand-edited?) \u2014 remove it by hand; nothing changed`);
  }
  const restored = parsed ? parsed.chain : null;
  if (parsed) {
    if (restored) {
      const rec = isObj(cfg.prev_statusline) ? cfg.prev_statusline : void 0;
      const next = { type: "command", command: restored };
      if (rec && rec.command === restored) {
        for (const k of ["padding", "refreshInterval"]) if (typeof rec[k] === "number") next[k] = rec[k];
      }
      settings.statusLine = next;
    } else {
      delete settings.statusLine;
    }
    await writeSettings(file, settings, raw);
  }
  await patchConfig(brainDir2, { react: null, chain: null, prev_statusline: null });
  try {
    await fs12.unlink(shimPath(brainDir2));
  } catch (e) {
    if (errCode(e) !== "ENOENT") throw e;
  }
  return { settings: file, restored, changed: !!parsed };
}

// src/cli/sb.ts
import { fileURLToPath } from "url";
var DRAIN_MAP_TIMEOUT_MS = 2e4;
var DRAIN_MAP_MAX_BUFFER = 8 * 1024 * 1024;
var REASON_CAP = 160;
function drainCursorMap(brainDir2, pluginRoot, timeoutMs) {
  return new Promise((resolve3) => {
    try {
      execFile2(
        resolveBashExe(),
        ["-c", '. "$1/scripts/lib.sh" && sb_drain_cursor_map', "sb-status", toBashPath(pluginRoot)],
        {
          env: { ...process.env, BRAIN_DIR: toBashPath(brainDir2) },
          timeout: timeoutMs,
          killSignal: "SIGKILL",
          maxBuffer: DRAIN_MAP_MAX_BUFFER,
          windowsHide: true
        },
        (err, stdout, stderr) => {
          if (err) {
            resolve3(drainMapFailure(err, String(stderr ?? ""), timeoutMs));
            return;
          }
          resolve3(String(stdout).split("\n").map((l) => l.replace(/\r$/, "")).filter(Boolean).map((l) => l.split("	")));
        }
      );
    } catch (e) {
      resolve3(sanitizeReason(e.message));
    }
  });
}
function drainMapFailure(err, stderr, timeoutMs) {
  if (err.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER") return `output over ${DRAIN_MAP_MAX_BUFFER / 1048576} MB`;
  if (err.killed) return `timed out after ${timeoutMs / 1e3} s`;
  if (err.signal) return `killed by ${err.signal}`;
  const why = stderr.trim() || err.message || "bash failed";
  return sanitizeReason(typeof err.code === "number" ? `exit ${err.code}: ${why}` : why);
}
var HELP = `Usage: sb <command> [args]

Commands:
  query <text>                                 Search the wiki (BM25 + vector hybrid)
  recall <text>                                Search past conversation transcripts
  pin user <text>                              Append a preference line to USER.md
  pin project <slug> <blockers|decisions> <text>
                                               Append an entry to a project's PROJECT.md
  status                                       Show hot-tier and wiki sizes
  auth [status|doctor]                         Show or fix the extractor auth mode
  buddy                                        Show the buddy card (the on-demand brain/thought-cloud card, its name, mute state)
  buddy name <name> | mute | unmute            Rename (1-14 chars) / silence the bubble
  buddy install | uninstall                    Add / remove the buddy statusLine in settings.json
  help                                         Show this message

Environment:
  BRAIN_DIR        Override second-brain dir (default: ~/.second-brain)
  KNOWLEDGE_DIR    Override knowledge dir    (default: ~/knowledge)
`;
async function hasClaudeOnPath() {
  const path = process.env.PATH ?? "";
  const names = process.platform === "win32" ? ["claude", "claude.exe", "claude.cmd"] : ["claude"];
  for (const rawDir2 of path.split(pathDelimiter)) {
    const dir = cleanEnvPath(rawDir2);
    if (!dir) continue;
    for (const name of names) {
      try {
        await fs13.access(join12(dir, name), fsConstants.X_OK);
        return true;
      } catch {
      }
    }
  }
  return false;
}
function claudeAuthStatus() {
  const timeout = Math.min(Math.max(Number(process.env.SB_AUTH_PROBE_TIMEOUT_MS) || 3e3, 100), 3e4);
  return new Promise((resolve3) => {
    try {
      execFile2(
        "claude",
        ["auth", "status"],
        { timeout, killSignal: "SIGKILL", maxBuffer: 256 * 1024, shell: process.platform === "win32" },
        (_err, stdout) => {
          const text = typeof stdout === "string" ? stdout.trim() : "";
          if (!text) {
            resolve3(null);
            return;
          }
          try {
            const parsed = JSON.parse(text);
            if (parsed && typeof parsed === "object") {
              resolve3(parsed);
              return;
            }
          } catch {
          }
          resolve3(null);
        }
      );
    } catch {
      resolve3(null);
    }
  });
}
function sanitizeField(v) {
  return String(v).replace(/[^\x20-\x7e]/g, "").slice(0, 40);
}
function sanitizeReason(v) {
  const flat = v.replace(/\s+/g, " ").replace(/[^\x20-\x7e]/g, "").trim();
  return flat.length > REASON_CAP ? `${flat.slice(0, REASON_CAP - 3)}...` : flat;
}
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
    const r = await knowledgeSearch({ query: q, knowledgeDir: deps.knowledgeDir, brainDir: deps.brainDir });
    if (r.candidates.length === 0) {
      push("(no results)");
    }
    for (const c of r.candidates.slice(0, 5)) {
      const slug = c.path.replace(/.*[\\/]/, "").replace(/\.md$/, "");
      const score = (c.score * 100).toFixed(0);
      push(`${score.padStart(3)}%  [[${slug}]]${c.description ? "  \u2014 " + c.description : ""}`);
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
      push(`${String(sim).padStart(3)}%  [${x.date} ${x.project}]  ${foldServedSnippet(displaySnippet(x, 100))}`);
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
    const userFile = join12(deps.brainDir, "USER.md");
    const projectsFile = join12(deps.brainDir, "projects.jsonl");
    let userBytes = 0, projectsCount = 0;
    try {
      userBytes = (await fs13.stat(userFile)).size;
    } catch {
    }
    try {
      const txt = await fs13.readFile(projectsFile, "utf-8");
      projectsCount = txt.split("\n").filter((l) => l.includes('"slug"')).length;
    } catch {
    }
    push(`USER.md:             ${userBytes} bytes`);
    push(`Registered projects: ${projectsCount}`);
    try {
      const projectDirs = await fs13.readdir(join12(deps.brainDir, "projects"), { withFileTypes: true });
      for (const d of projectDirs) {
        if (!d.isDirectory()) continue;
        const pf = join12(deps.brainDir, "projects", d.name, "PROJECT.md");
        try {
          const size = (await fs13.stat(pf)).size;
          push(`  ${d.name}/PROJECT.md: ${size} bytes`);
        } catch {
        }
      }
    } catch {
    }
    try {
      const wikiDirs = await fs13.readdir(join12(deps.knowledgeDir, "wiki"), { withFileTypes: true });
      push("Wiki pages:");
      for (const d of wikiDirs) {
        if (!d.isDirectory()) continue;
        const files = await fs13.readdir(join12(deps.knowledgeDir, "wiki", d.name));
        const count = files.filter((f) => f.endsWith(".md") && f !== "index.md").length;
        push(`  ${d.name}: ${count}`);
      }
    } catch {
    }
    push("Loop liveness:");
    const age = (ms) => {
      const h = (Date.now() - ms) / 36e5;
      if (h < 1) return `${Math.max(1, Math.round(h * 60))}m ago`;
      if (h < 48) return `${Math.round(h)}h ago`;
      return `${Math.round(h / 24)}d ago`;
    };
    try {
      const hf = join12(deps.brainDir, ".extractor-health.json");
      const st = await fs13.stat(hf);
      const h = JSON.parse(await fs13.readFile(hf, "utf-8"));
      push(`  drainer last ran:    ${age(st.mtimeMs)} (${sanitizeField(h.status ?? "?")}: ${sanitizeField(h.reason ?? "?")})`);
    } catch {
      push("  drainer last ran:    never (no .extractor-health.json)");
    }
    try {
      const stateRaw = await fs13.readFile(join12(deps.brainDir, ".extraction-state.jsonl"), "utf-8");
      let newestTs = "";
      for (const l of stateRaw.split("\n").filter(Boolean)) {
        try {
          const r = JSON.parse(l);
          if (r.ts && r.ts > newestTs) newestTs = r.ts;
        } catch {
        }
      }
      push(`  last extraction:     ${newestTs ? sanitizeField(newestTs) : "never"}`);
    } catch {
      push("  last extraction:     never (no .extraction-state.jsonl)");
    }
    try {
      await fs13.access(join12(deps.brainDir, "transcripts"));
      const root = deps.pluginRoot ?? fileURLToPath(new URL("../../../", import.meta.url));
      const map = await drainCursorMap(deps.brainDir, root, deps.drainMapTimeoutMs ?? DRAIN_MAP_TIMEOUT_MS);
      if (typeof map === "string") {
        push(`  transcript backlog:  unknown (drain cursor map unavailable: ${map})`);
      } else {
        const pending = map.filter((r) => r[3] === "pending").length;
        const dead = map.filter((r) => r[3] === "dead").length;
        const count = (v) => v && /^[0-9]+$/.test(v) ? Number(v) : 0;
        let deadArchives = 0, deadWindows = 0, deadLines = 0;
        for (const r of map) {
          const dw = count(r[8]);
          if (dw === 0) continue;
          deadArchives++;
          deadWindows += dw;
          deadLines += count(r[9]);
        }
        const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;
        push(`  transcript backlog:  ${pending} of ${map.length} archived${dead ? ` (${dead} dead-lettered)` : ""}` + (deadArchives ? `; dead windows: ${deadWindows} in ${plural(deadArchives, "archive")}, ${plural(deadLines, "line")}` : ""));
      }
    } catch {
      push("  transcript backlog:  no transcripts dir");
    }
    try {
      await fs13.stat(join12(deps.brainDir, SCRUB_MARK));
      push("  archive scrub:       done");
    } catch {
      try {
        const todo = parseScrubTodo(await fs13.readFile(join12(deps.brainDir, SCRUB_TODO), "utf-8"));
        const stuck = todo.filter((e) => e.fails >= 3).length;
        push(`  archive scrub:       ${todo.length} to scrub (${stuck} with failed attempts >= 3)`);
      } catch (e) {
        push(e.code === "ENOENT" ? `  archive scrub:       no to-do list yet (no ${SCRUB_TODO}, no ${SCRUB_MARK} marker)` : `  archive scrub:       unknown (cannot read ${SCRUB_TODO}: ${sanitizeReason(e.message ?? String(e))})`);
      }
    }
    try {
      await fs13.access(join12(deps.brainDir, "bin", "sb-extract-drain.sh"));
      push("  scheduler shim:      present");
    } catch {
      push("  scheduler shim:      ABSENT (out-of-band drain cannot run)");
    }
    try {
      const dreamsDir = join12(deps.brainDir, "dreams");
      const ids = (await fs13.readdir(dreamsDir)).filter((d) => d.startsWith("drm_")).sort();
      if (ids.length === 0) {
        push("  newest dream:        none");
      } else {
        const id = ids[ids.length - 1];
        const sf = join12(dreamsDir, id, "status.json");
        const st = await fs13.stat(sf);
        const s = JSON.parse(await fs13.readFile(sf, "utf-8"));
        push(`  newest dream:        ${sanitizeField(id)} ${sanitizeField(s.status ?? "?")} (heartbeat ${age(st.mtimeMs)})`);
      }
    } catch {
      push("  newest dream:        none");
    }
    try {
      const projectDirs = await fs13.readdir(join12(deps.brainDir, "projects"), { withFileTypes: true });
      let raw = 0;
      for (const d of projectDirs) {
        if (!d.isDirectory()) continue;
        try {
          raw += await unprocessedCount(deps.brainDir, d.name);
        } catch {
        }
      }
      push(`  raw-inbox depth:     ${raw} unprocessed`);
    } catch {
      push("  raw-inbox depth:     0 unprocessed (no projects dir)");
    }
    push("Utilization:");
    let util = {};
    try {
      util = JSON.parse(await fs13.readFile(join12(deps.brainDir, "utilization-counts.json"), "utf-8"));
      if (util === null || typeof util !== "object" || Array.isArray(util)) util = {};
    } catch {
    }
    const entries = Object.entries(util).filter(([, v]) => v && typeof v.count === "number");
    if (entries.length === 0) push("  (no invocations recorded yet)");
    else {
      entries.sort((a, b) => (b[1].count ?? 0) - (a[1].count ?? 0));
      for (const [name, v] of entries.slice(0, 5)) {
        push(`  ${sanitizeField(name)}: ${v.count} (last ${sanitizeField(v.last_used ?? "?")})`);
      }
    }
    try {
      const pluginRoot = new URL("../../../", import.meta.url);
      const { fileURLToPath: fileURLToPath2 } = await import("url");
      const root = fileURLToPath2(pluginRoot);
      const skills = (await fs13.readdir(join12(root, "skills"), { withFileTypes: true })).filter((d) => d.isDirectory()).map((d) => `skill!${d.name}`);
      const agents = (await fs13.readdir(join12(root, "agents"))).filter((f) => f.endsWith(".md")).map((f) => `agent!${f.replace(/\.md$/, "")}`);
      const used = new Set(Object.keys(util));
      const isUsed = (kind, name) => {
        for (const k of used) {
          if (!k.startsWith(kind + ":")) continue;
          if (k === `${kind}:${name}` || k.endsWith(`:${name}`)) return true;
        }
        return false;
      };
      const dormant = [...skills, ...agents].map((t) => t.split("!")).filter(([kind, name]) => !isUsed(kind, name)).map(([kind, name]) => `${kind}:${name}`);
      const total = skills.length + agents.length;
      if (dormant.length === 0) push(`  dormant: none of ${total} shipped capabilities`);
      else push(`  dormant: ${dormant.length} of ${total} shipped capabilities (${dormant.slice(0, 6).map(sanitizeField).join(", ")}${dormant.length > 6 ? ", \u2026" : ""})`);
    } catch {
    }
    return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
  }
  if (cmd === "buddy") {
    if (args[1]?.startsWith("--")) {
      errpush(`buddy: unknown option ${args[1]} (the account roll and --rehatch are gone)`);
      return { stdout: "", stderr: err.join("\n"), exitCode: 2 };
    }
    const sub = args[1] ?? "";
    if (sub === "name") {
      const name = args.slice(2).join(" ").trim();
      if (!validName(name)) {
        errpush("buddy name: 1-14 printable characters");
        return { stdout: "", stderr: err.join("\n"), exitCode: 2 };
      }
      try {
        await patchConfig(deps.brainDir, { name });
      } catch (e) {
        errpush(`buddy name: ${e.message}`);
        return { stdout: "", stderr: err.join("\n"), exitCode: 1 };
      }
      push(`buddy is now called ${name}`);
      return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
    }
    if (sub === "mute" || sub === "unmute") {
      try {
        await patchConfig(deps.brainDir, { mute: sub === "mute" });
      } catch (e) {
        errpush(`buddy ${sub}: ${e.message}`);
        return { stdout: "", stderr: err.join("\n"), exitCode: 1 };
      }
      push(sub === "mute" ? "buddy bubble muted (telemetry line stays)" : "buddy bubble unmuted");
      return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
    }
    if (sub === "install" || sub === "uninstall") {
      const here = fileURLToPath(import.meta.url);
      const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT || join12(here, "..", "..", "..", "..");
      try {
        if (sub === "install") {
          await dropStaleIdentity(deps.brainDir);
          const r = await installStatusline(deps.brainDir, pluginRoot);
          if (!r.changed) {
            push(`buddy statusLine already installed in ${r.settings} (shim refreshed: ${r.shim})`);
          } else {
            push(`statusLine set in ${r.settings} (refreshInterval 1 \u2014 the animation tick)`);
            push(`  command: ${r.command}`);
            push(`  shim: ${r.shim} (resolves the newest installed plugin version at run time)`);
            if (r.chained) push(`  previous statusline kept as line 1: ${r.chained}`);
            if (r.backup) push(`  backup: ${r.backup}`);
            push("restart Claude Code to see the buddy; undo: sb buddy uninstall");
          }
          push("two-way chat on: each prompt carries one [buddy] line and Claude ends the turn with buddy_react");
          push(`  (one extra tool call per turn; if Claude Code asks to allow buddy_react, choose "don't ask again";`);
          push("   keep the display without it: SB_BUDDY_REACT=off)");
        } else {
          const r = await uninstallStatusline(deps.brainDir);
          if (!r.changed) push(`no buddy statusLine in ${r.settings} \u2014 nothing to remove (two-way chat off)`);
          else push(r.restored ? `statusLine restored to: ${r.restored}` : `buddy statusLine removed from ${r.settings}`);
        }
      } catch (e) {
        errpush(`buddy ${sub}: ${e.message}`);
        return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 1 };
      }
      return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
    }
    if (sub) {
      errpush(`buddy: unknown subcommand ${sub}`);
      return { stdout: "", stderr: err.join("\n"), exitCode: 2 };
    }
    await dropStaleIdentity(deps.brainDir);
    const cfg = await readConfig(deps.brainDir);
    push(renderCard(buddyName(cfg)));
    if (cfg.mute === true) push("  bubble: muted (sb buddy unmute)");
    push("  rename: sb buddy name <x>   statusline: sb buddy install");
    return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
  }
  if (cmd === "auth") {
    const sub = args[1] ?? "status";
    if (sub === "status") {
      const key = process.env.ANTHROPIC_API_KEY;
      if (key && key.length > 0) {
        push("mode: api-key");
        push(`key:  ${key.slice(0, 10)}\u2026 (len=${key.length})`);
        push("backend: anthropic-api (direct curl)");
        push("note: works in all contexts (Stop hooks, cron, CI)");
        return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
      }
      if (!await hasClaudeOnPath()) {
        push("mode: none");
        push("backend: none \u2014 neither ANTHROPIC_API_KEY nor `claude` CLI is available");
        push("run: sb auth doctor");
        return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
      }
      const st = await claudeAuthStatus();
      if (!st || typeof st.loggedIn !== "boolean") {
        push("mode: unknown");
        push("backend: claude CLI present, but `claude auth status` did not return parseable JSON (timeout or old CLI)");
        push("run: claude auth status   # inspect the raw auth state yourself");
        return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
      }
      if (!st.loggedIn) {
        push("mode: none (logged out)");
        push("backend: none \u2014 `claude auth status` reports loggedIn=false");
        push("fix: run `claude /login` (OAuth) or `export ANTHROPIC_API_KEY=sk-ant-...`");
        return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
      }
      if (st.authMethod === "api_key") {
        push("mode: api-key (claude-managed)");
        push("backend: claude CLI (api_key via apiKeyHelper / setup-token)");
        push("auth: verified via `claude auth status` (authMethod=api_key)");
        push("note: extraction still uses the recursive `claude` CLI path, so in-session Stop/PreCompact");
        push("      extraction queues (recursive-claude lock). Set ANTHROPIC_API_KEY for the direct-curl backend.");
        return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
      }
      push("mode: subscription");
      push("backend: claude CLI (OAuth via `claude /login`)");
      if (typeof st.authMethod === "string" && st.authMethod.length > 0) {
        push(`auth: verified via \`claude auth status\` (authMethod=${sanitizeField(st.authMethod)})`);
      } else {
        push("auth: verified via `claude auth status` (loggedIn=true, authMethod unspecified)");
      }
      push("note: real-time extraction inside a Claude Code session is NOT possible in this mode");
      push("      due to the recursive-claude OAuth lock. Set ANTHROPIC_API_KEY for in-session extraction,");
      push("      or rely on out-of-band extraction (see `sb auth doctor`).");
      return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
    }
    if (sub === "doctor") {
      push("Auth doctor \u2014 two supported modes:");
      push("");
      push("1. Anthropic API key (token plan)");
      push("   export ANTHROPIC_API_KEY=sk-ant-...");
      push("   Works in all contexts (Stop hooks, cron, CI).");
      push("   Recommended for in-session extraction.");
      push("");
      push("2. Claude subscription (OAuth)");
      push("   claude /login   # interactive browser flow");
      push("   Works outside Claude Code (cron, CI). Inside a Claude Code session,");
      push("   Stop/PreCompact extractors will queue (recursive-claude OAuth lock).");
      push("");
      push("After either, verify with: sb auth status");
      return { stdout: out.join("\n"), stderr: err.join("\n"), exitCode: 0 };
    }
    errpush(`auth: unknown subcommand '${sub}'  \u2014 usage: sb auth {status|doctor}`);
    return { stdout: "", stderr: err.join("\n"), exitCode: 2 };
  }
  errpush(`unknown command: ${cmd}`);
  errpush("run: sb help");
  return { stdout: "", stderr: err.join("\n"), exitCode: 2 };
}

// src/cli/sb-entry.ts
var brainDir = resolveBrainDir();
var knowledgeDir = resolveKnowledgeDir();
var result = await runSb(process.argv.slice(2), { brainDir, knowledgeDir });
if (result.stdout) process.stdout.write(result.stdout + "\n");
if (result.stderr) process.stderr.write(result.stderr + "\n");
process.exit(result.exitCode);
