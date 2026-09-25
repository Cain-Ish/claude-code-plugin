#!/usr/bin/env node

// src/tools/jit-index.ts
import { promises as fs3 } from "fs";
import { basename, join as join3 } from "path";
import { execFile } from "child_process";
import { promisify } from "util";

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
import { join, isAbsolute as isAbsolute2 } from "path";
import { homedir } from "os";
function resolveBrainDir(override) {
  if (override) return override;
  return cleanEnvPath(process.env.SB_BRAIN_DIR || process.env.BRAIN_DIR) || join(homedir(), ".second-brain");
}
function resolveKnowledgeDir(override) {
  if (override) return override;
  for (const raw of [process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR, process.env.KNOWLEDGE_DIR]) {
    const c = cleanEnvPath(raw);
    if (!c.trim() || c.includes("${")) continue;
    return c.startsWith("~") ? join(homedir(), c.slice(1)) : c;
  }
  return join(homedir(), "knowledge");
}

// ../kb-schema.json
var kb_schema_default = {
  _comment: "SINGLE SOURCE OF TRUTH for the second-brain knowledge-base structure. Edit HERE only. Read by the TS MCP server via mcp/src/constants/kb-schema.ts (esbuild inlines this JSON) and by every bash script/hook via scripts/kb-schema.sh (sourced by lib.sh, reads this file with jq). Derived sets (content/all categories) are computed by the loaders, never stored, so they cannot drift. Guarded by tests/test-kb-schema.sh.",
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
  project_sections: ["blockers", "decisions", "conventions"],
  forget_protection: {
    protected: ["learnings", "decisions", "concepts", "security", "themes", "projects"],
    discounted: ["entities", "sources", "issues"]
  },
  raw: {
    dir: "raw",
    tier: "project",
    statuses: ["unprocessed", "processed", "discarded"],
    searchable: false
  }
};

// src/constants/kb-schema.ts
var STRUCTURED_TYPES = kb_schema_default.structured_types;
var UNSTRUCTURED_TYPES = kb_schema_default.unstructured_types;
var GENERATED_DIRS = kb_schema_default.generated_dirs;
var EDGE_TYPES = kb_schema_default.edge_types;
var PROJECT_SECTIONS = kb_schema_default.project_sections;
var FORGET_PROTECTED = kb_schema_default.forget_protection.protected;
var FORGET_DISCOUNTED = kb_schema_default.forget_protection.discounted;
var RAW_DIR = kb_schema_default.raw.dir;
var RAW_STATUSES = kb_schema_default.raw.statuses;
var CANDIDATE_FACTS = kb_schema_default.candidate_facts;
var FRONTMATTER_REQUIRED = kb_schema_default.frontmatter_required;
var AI_BLOCK_TYPES = kb_schema_default.ai_blocks.types;
var CONTENT_CATEGORIES = [...STRUCTURED_TYPES, ...UNSTRUCTURED_TYPES];
var ALL_CATEGORIES = [...CONTENT_CATEGORIES, ...GENERATED_DIRS];

// src/tools/ai-block.ts
var AI_BLOCK_RE = /<!--\s*ai:begin[^\n]*?-->\n?([\s\S]*?)<!--\s*ai:end\s*-->/;
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
import { promises as fs } from "fs";
import { join as join2 } from "path";
async function walkWiki(dir, opts = {}, acc = []) {
  let entries;
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return acc;
  }
  for (const e of entries) {
    if (opts.skipHidden && e.name.startsWith(".")) continue;
    const p = join2(dir, e.name);
    if (e.isDirectory()) {
      if (opts.skipDirs?.includes(e.name)) continue;
      await walkWiki(p, opts, acc);
    } else if (e.isFile() && e.name.endsWith(".md") && (opts.includeIndex || e.name !== "index.md")) {
      acc.push(opts.posix ? p.replace(/\\/g, "/") : p);
    }
  }
  return acc;
}

// src/tools/sanitize.ts
var INVISIBLE_RE = /[\u{200B}\u{2060}\u{FEFF}\u{E0000}-\u{E007F}]/gu;
function stripInvisible(s) {
  return s.replace(INVISIBLE_RE, "");
}

// src/tools/atomic-write.ts
import { promises as fs2 } from "fs";
async function atomicWriteJson(filePath, value) {
  const tmp = `${filePath}.tmp.${process.pid}`;
  try {
    await fs2.writeFile(tmp, JSON.stringify(value));
    await fs2.rename(tmp, filePath);
  } catch (err) {
    console.error(
      `atomicWriteJson: FAILED to write ${filePath}: ${err instanceof Error ? err.message : String(err)}`
    );
    try {
      await fs2.unlink(tmp);
    } catch {
    }
  }
}

// src/tools/jit-index.ts
var MAX_ITEMS = 200;
var MAX_GLOBS_PER_ITEM = 8;
var LINE_CAP = 160;
var CONTROL_RE = /[\u0000-\u001f\u007f-\u009f`\r\n]/g;
function sanitizeRaw(s) {
  if (!s) return "";
  let out = stripInvisible(s);
  out = out.replace(CONTROL_RE, " ");
  out = out.replace(/\\/g, " ");
  out = out.replace(/\s+/g, " ").trim();
  return out;
}
function buildLine(a, b) {
  const A = sanitizeRaw(a);
  const B = sanitizeRaw(b);
  if (A && B) return `${A} \u2192 ${B}`;
  if (A) return A;
  if (B) return B;
  return null;
}
var PATH_TOKEN_RE = /(?:^|[\s("'`,;:])([A-Za-z0-9_][A-Za-z0-9_./-]*(?:\.[A-Za-z0-9]{1,8}|\/))(?=$|[\s)"'`,;:.])/g;
function extractPathTokens(text) {
  const out = [];
  const re = new RegExp(PATH_TOKEN_RE.source, "g");
  let m;
  while ((m = re.exec(text)) !== null) {
    out.push(m[1]);
    if (m[0].length === 0) re.lastIndex++;
  }
  return out;
}
function extractGlobs(text, repoSet, repoFiles) {
  const tokens = extractPathTokens(text);
  const globs = [];
  const seen = /* @__PURE__ */ new Set();
  for (const tok of tokens) {
    let g = null;
    if (tok.endsWith("/")) {
      if (repoFiles.some((f) => f.startsWith(tok))) g = `${tok}*`;
    } else if (repoSet.has(tok)) {
      g = tok;
    }
    if (g && !seen.has(g)) {
      seen.add(g);
      globs.push(g);
      if (globs.length >= MAX_GLOBS_PER_ITEM) break;
    }
  }
  return globs;
}
var KIND_PRIORITY = { lesson: 0, convention: 1, decision: 2, intent: 3 };
function buildJitIndex(input) {
  const repoSet = new Set(input.repoFiles);
  const items = [];
  for (const page of input.pages) {
    if (page.project !== input.slug) continue;
    const ab = page.aiBlock || {};
    let kind;
    let line;
    switch (page.type) {
      case "issues":
        kind = "lesson";
        line = buildLine(ab.symptom, ab.fix);
        break;
      case "learnings":
        kind = "lesson";
        line = buildLine(ab.claim, ab.action);
        break;
      case "decisions": {
        const status = (page.status ?? ab.status ?? "").trim();
        if (/^(superseded|rejected)\b/i.test(status)) continue;
        kind = "decision";
        line = buildLine(ab.choice, void 0);
        break;
      }
      case "concepts":
        kind = "intent";
        line = buildLine(ab.problem, void 0);
        break;
      default:
        continue;
    }
    if (!line) continue;
    const globs = extractGlobs(line, repoSet, input.repoFiles);
    if (globs.length === 0) continue;
    items.push({ id: page.slug, kind, globs, line: line.slice(0, LINE_CAP) });
  }
  input.conventions.forEach((raw, i) => {
    const text = sanitizeRaw(raw);
    if (!text) return;
    const globs = extractGlobs(text, repoSet, input.repoFiles);
    if (globs.length === 0) return;
    items.push({ id: `conv:${i + 1}`, kind: "convention", globs, line: text.slice(0, LINE_CAP) });
  });
  items.sort((a, b) => {
    const pa = KIND_PRIORITY[a.kind], pb = KIND_PRIORITY[b.kind];
    if (pa !== pb) return pa - pb;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
  return { schema: 1, slug: input.slug, items: items.slice(0, MAX_ITEMS) };
}
async function readConventions(projectFile) {
  let content;
  try {
    content = await fs3.readFile(projectFile, "utf-8");
  } catch {
    return [];
  }
  const lines = content.split("\n");
  const idx = lines.findIndex((l) => l.trim() === "## Conventions");
  if (idx < 0) return [];
  const out = [];
  for (let i = idx + 1; i < lines.length; i++) {
    const l = lines[i];
    if (l.startsWith("## ")) break;
    const t = l.replace(/\r$/, "").trim();
    if (t.startsWith("- ")) out.push(t.slice(2));
  }
  return out;
}
async function loadProjectPages(knowledgeDir) {
  const wikiRoot = join3(knowledgeDir, "wiki");
  const pages = [];
  let entries;
  try {
    entries = await fs3.readdir(wikiRoot, { withFileTypes: true });
  } catch {
    return pages;
  }
  const dirs = entries.filter((d) => d.isDirectory() && d.name !== "projects").map((d) => d.name);
  for (const dir of dirs) {
    let files;
    try {
      files = await walkWiki(join3(wikiRoot, dir));
    } catch {
      continue;
    }
    for (const filePath of files) {
      try {
        const content = await fs3.readFile(filePath, "utf-8");
        const doc = parseDoc(content, filePath);
        pages.push({
          slug: basename(filePath).replace(/\.md$/, ""),
          type: dir,
          project: doc.project,
          aiBlock: doc.aiBlock ?? {}
        });
      } catch {
      }
    }
  }
  return pages;
}
var execFileAsync = promisify(execFile);
async function defaultGitRunner(args, cwd) {
  const { stdout } = await execFileAsync("git", args, {
    cwd,
    maxBuffer: 64 * 1024 * 1024,
    windowsHide: true,
    timeout: 5e3
  });
  return stdout;
}
function isNoGitError(e) {
  const err = e;
  if (!err) return false;
  if (err.code === "ENOENT" || err.code === 128 || err.code === "128") return true;
  const stderrText = typeof err.stderr === "string" ? err.stderr : err.stderr?.toString("utf-8") ?? "";
  const msg = err.message ?? "";
  return /not a git repository/i.test(stderrText) || /not a git repository/i.test(msg);
}
async function rebuildJitIndex(opts) {
  validateSlug(opts.slug);
  const dir = resolveBrainDir(opts.brainDir);
  const projectFile = assertWithin(dir, "projects", opts.slug, "PROJECT.md");
  const [pages, conventions] = await Promise.all([
    loadProjectPages(opts.knowledgeDir),
    readConventions(projectFile)
  ]);
  const runGit = opts.runGit ?? defaultGitRunner;
  let repoFiles = [];
  let gitRev = "nogit";
  let lsFilesOk = false;
  try {
    const out = await runGit(["ls-files", "-z"], opts.repoRoot);
    repoFiles = out.split("\0").filter(Boolean);
    lsFilesOk = true;
  } catch (e) {
    if (!isNoGitError(e)) {
      const code = e?.code ?? "unknown";
      throw new Error(`jit-index: git ls-files failed (${code}) \u2014 index NOT rewritten`);
    }
    console.error(JSON.stringify({
      event: "jit-index-no-git",
      repoRoot: opts.repoRoot,
      err: e instanceof Error ? e.message : String(e)
    }));
  }
  if (lsFilesOk) {
    try {
      const out = await runGit(["rev-parse", "HEAD"], opts.repoRoot);
      gitRev = out.trim() || "nogit";
    } catch {
      gitRev = "nogit";
    }
  }
  const core = buildJitIndex({ slug: opts.slug, pages, conventions, repoFiles });
  const index = { ...core, generated_at: (/* @__PURE__ */ new Date()).toISOString(), git_rev: gitRev };
  const outPath = assertWithin(dir, "projects", opts.slug, "jit-index.json");
  await fs3.mkdir(join3(dir, "projects", opts.slug), { recursive: true });
  await atomicWriteJson(outPath, index);
  return index;
}

// src/tools/jit-index-cli.ts
async function main() {
  const slug = process.argv[2];
  const repoRoot = process.argv[3];
  if (!slug || !repoRoot) {
    console.error(JSON.stringify({ event: "jit-index-cli-bad-args", argv: process.argv.slice(2) }));
    process.exitCode = 1;
    return;
  }
  try {
    await rebuildJitIndex({
      brainDir: resolveBrainDir(),
      knowledgeDir: resolveKnowledgeDir(),
      slug,
      repoRoot
    });
    process.exitCode = 0;
  } catch (e) {
    console.error(JSON.stringify({ event: "jit-index-cli-failed", err: e instanceof Error ? e.message : String(e) }));
    process.exitCode = 1;
  }
}
main();
