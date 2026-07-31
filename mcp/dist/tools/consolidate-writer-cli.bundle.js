var __defProp = Object.defineProperty;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __esm = (fn, res) => function __init() {
  return fn && (res = (0, fn[__getOwnPropNames(fn)[0]])(fn = 0)), res;
};
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};

// src/path-guard.ts
import { resolve, sep, isAbsolute } from "path";
import { realpathSync } from "fs";
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
var PathGuardError;
var init_path_guard = __esm({
  "src/path-guard.ts"() {
    "use strict";
    PathGuardError = class extends Error {
      constructor(message, baseDir, candidate) {
        super(message);
        this.baseDir = baseDir;
        this.candidate = candidate;
        this.name = "PathGuardError";
      }
      baseDir;
      candidate;
    };
  }
});

// ../kb-schema.json
var kb_schema_default;
var init_kb_schema = __esm({
  "../kb-schema.json"() {
    kb_schema_default = {
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
      project_sections: ["blockers", "decisions"],
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
  }
});

// src/constants/kb-schema.ts
var STRUCTURED_TYPES, UNSTRUCTURED_TYPES, GENERATED_DIRS, EDGE_TYPES, PROJECT_SECTIONS, FORGET_PROTECTED, FORGET_DISCOUNTED, RAW_DIR, RAW_STATUSES, CANDIDATE_FACTS, FRONTMATTER_REQUIRED, AI_BLOCK_TYPES, CONTENT_CATEGORIES, ALL_CATEGORIES;
var init_kb_schema2 = __esm({
  "src/constants/kb-schema.ts"() {
    "use strict";
    init_kb_schema();
    STRUCTURED_TYPES = kb_schema_default.structured_types;
    UNSTRUCTURED_TYPES = kb_schema_default.unstructured_types;
    GENERATED_DIRS = kb_schema_default.generated_dirs;
    EDGE_TYPES = kb_schema_default.edge_types;
    PROJECT_SECTIONS = kb_schema_default.project_sections;
    FORGET_PROTECTED = kb_schema_default.forget_protection.protected;
    FORGET_DISCOUNTED = kb_schema_default.forget_protection.discounted;
    RAW_DIR = kb_schema_default.raw.dir;
    RAW_STATUSES = kb_schema_default.raw.statuses;
    CANDIDATE_FACTS = kb_schema_default.candidate_facts;
    FRONTMATTER_REQUIRED = kb_schema_default.frontmatter_required;
    AI_BLOCK_TYPES = kb_schema_default.ai_blocks.types;
    CONTENT_CATEGORIES = [...STRUCTURED_TYPES, ...UNSTRUCTURED_TYPES];
    ALL_CATEGORIES = [...CONTENT_CATEGORIES, ...GENERATED_DIRS];
  }
});

// src/tools/sanitize.ts
function stripInvisible(s) {
  return s.replace(INVISIBLE_RE, "");
}
var INVISIBLE_RE;
var init_sanitize = __esm({
  "src/tools/sanitize.ts"() {
    "use strict";
    INVISIBLE_RE = /[\u{200B}\u{2060}\u{FEFF}\u{E0000}-\u{E007F}]/gu;
  }
});

// src/tools/candidate-facts.ts
var candidate_facts_exports = {};
__export(candidate_facts_exports, {
  FACT_KINDS: () => FACT_KINDS,
  KIND_TO_CATEGORY: () => KIND_TO_CATEGORY,
  MAX_FACTS: () => MAX_FACTS,
  RELATION_EDGE_TYPES: () => RELATION_EDGE_TYPES,
  sanitizeFactLine: () => sanitizeFactLine,
  sanitizeFactString: () => sanitizeFactString,
  validateCandidateFacts: () => validateCandidateFacts
});
function sanitizeFactString(s) {
  return stripInvisible(s).replace(/\r/g, "").replace(/<!--/g, "(!--").replace(/-->/g, "--)").replace(/[\x00-\x08\x0b-\x1f\x7f]/g, " ");
}
function sanitizeFactLine(s) {
  return sanitizeFactString(s).replace(/\n+/g, " ").trim();
}
function validateCandidateFacts(raw) {
  const out = { facts: [], rejected: [] };
  if (typeof raw !== "object" || raw === null || !Array.isArray(raw.facts)) {
    out.rejected.push({ index: -1, reason: "document is not an object with a facts array" });
    return out;
  }
  const arr = raw.facts;
  arr.forEach((item, index) => {
    if (index >= MAX_FACTS) {
      out.rejected.push({ index, reason: `over maxItems ${MAX_FACTS}` });
      return;
    }
    if (typeof item !== "object" || item === null) {
      out.rejected.push({ index, reason: "fact is not an object" });
      return;
    }
    const f = item;
    const kind = typeof f.kind === "string" ? f.kind : "";
    if (!FACT_KINDS.includes(kind)) {
      out.rejected.push({ index, reason: `kind '${String(f.kind)}' not in closed vocabulary` });
      return;
    }
    if (typeof f.claim !== "string" || f.claim.length === 0) {
      out.rejected.push({ index, reason: "claim missing/empty" });
      return;
    }
    for (const [field, cap] of Object.entries(CAPS)) {
      const v = f[field];
      if (v !== void 0 && (typeof v !== "string" || v.length > cap)) {
        out.rejected.push({ index, reason: `${field} not a string or over ${cap}-char cap` });
        return;
      }
    }
    if (f.confidence !== void 0 && !CONFIDENCE.includes(f.confidence)) {
      out.rejected.push({ index, reason: `confidence '${String(f.confidence)}' not in closed vocabulary` });
      return;
    }
    const fact = { kind, claim: sanitizeFactLine(f.claim) };
    if (typeof f.title === "string") fact.title = sanitizeFactLine(f.title);
    if (typeof f.evidence === "string") fact.evidence = sanitizeFactLine(f.evidence);
    if (typeof f.source === "string") fact.source = sanitizeFactLine(f.source);
    if (typeof f.confidence === "string") fact.confidence = f.confidence;
    if (kind === "relation") {
      const fh = typeof f.from_hint === "string" ? sanitizeFactLine(f.from_hint) : "";
      const th = typeof f.to_hint === "string" ? sanitizeFactLine(f.to_hint) : "";
      const rl = typeof f.rel === "string" ? f.rel : "relates";
      if (!fh || !th) {
        out.rejected.push({ index, reason: "relation fact missing from_hint/to_hint" });
        return;
      }
      if (!RELATION_EDGE_TYPES.includes(rl)) {
        out.rejected.push({ index, reason: `relation rel '${rl}' not permitted unattended (allowed: ${RELATION_EDGE_TYPES.join(", ")})` });
        return;
      }
      fact.from_hint = fh;
      fact.to_hint = th;
      fact.rel = rl;
    }
    if (fact.claim.trim().length === 0) {
      out.rejected.push({ index, reason: "claim empty after sanitization" });
      return;
    }
    out.facts.push(fact);
  });
  return out;
}
var ITEM_PROPS, FACT_KINDS, KIND_TO_CATEGORY, RELATION_EDGE_TYPES, MAX_FACTS, CAPS, CONFIDENCE;
var init_candidate_facts = __esm({
  "src/tools/candidate-facts.ts"() {
    "use strict";
    init_kb_schema2();
    init_sanitize();
    ITEM_PROPS = CANDIDATE_FACTS.json_schema.properties.facts.items.properties;
    FACT_KINDS = ITEM_PROPS.kind.enum;
    KIND_TO_CATEGORY = CANDIDATE_FACTS.kind_to_category;
    RELATION_EDGE_TYPES = CANDIDATE_FACTS.relation_edge_types;
    MAX_FACTS = CANDIDATE_FACTS.json_schema.properties.facts.maxItems;
    CAPS = Object.fromEntries(
      Object.entries(ITEM_PROPS).filter(([, p]) => typeof p.maxLength === "number").map(([k, p]) => [k, p.maxLength])
    );
    CONFIDENCE = ITEM_PROPS.confidence.enum;
  }
});

// src/tools/content-hash.ts
var init_content_hash = __esm({
  "src/tools/content-hash.ts"() {
    "use strict";
  }
});

// src/tools/ai-block.ts
var AI_BLOCK_RE, AI_BLOCK_RE_G;
var init_ai_block = __esm({
  "src/tools/ai-block.ts"() {
    "use strict";
    init_kb_schema2();
    AI_BLOCK_RE = /<!--\s*ai:begin[^\n]*?-->\n?([\s\S]*?)<!--\s*ai:end\s*-->/;
    AI_BLOCK_RE_G = new RegExp(AI_BLOCK_RE.source, "g");
  }
});

// src/tools/frontmatter.ts
function matchFrontmatter(content) {
  const m = content.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  return m ? { fm: m[1], body: m[2] } : null;
}
var init_frontmatter = __esm({
  "src/tools/frontmatter.ts"() {
    "use strict";
    init_ai_block();
  }
});

// src/tools/graph-cluster.ts
var init_graph_cluster = __esm({
  "src/tools/graph-cluster.ts"() {
    "use strict";
  }
});

// src/tools/minhash.ts
var NUM_HASHES, A, B;
var init_minhash = __esm({
  "src/tools/minhash.ts"() {
    "use strict";
    init_graph_cluster();
    init_ai_block();
    init_sanitize();
    init_frontmatter();
    NUM_HASHES = 128;
    A = new Uint32Array(NUM_HASHES);
    B = new Uint32Array(NUM_HASHES);
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
  }
});

// src/tools/raw-inbox.ts
function slugify(text) {
  const s = text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40);
  return s || "item";
}
var init_raw_inbox = __esm({
  "src/tools/raw-inbox.ts"() {
    "use strict";
    init_path_guard();
    init_content_hash();
    init_frontmatter();
    init_sanitize();
    init_minhash();
    init_sanitize();
  }
});

// src/tools/consolidate-writer.ts
var consolidate_writer_exports = {};
__export(consolidate_writer_exports, {
  appendToUntrustedSection: () => appendToUntrustedSection,
  applyCandidates: () => applyCandidates,
  factHash: () => factHash,
  isFoldInMatch: () => isFoldInMatch
});
import { promises as fs } from "fs";
import { join, relative, isAbsolute as isAbsolute2, resolve as resolve2 } from "path";
function titleTokens(s) {
  return s.toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length > 2 && !TITLE_STOP.has(t));
}
function isFoldInMatch(factTitle, factClaim, pageSlug, pageTitle) {
  if (slugify(factTitle) === pageSlug) return true;
  const pt = titleTokens(pageTitle);
  if (pt.length === 0) return false;
  const factSet = /* @__PURE__ */ new Set([...titleTokens(factTitle), ...titleTokens(factClaim)]);
  return pt.every((t) => factSet.has(t));
}
function factHash(f) {
  const s = `${f.kind}|${f.claim}`;
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = (h << 5) + h + s.charCodeAt(i) | 0;
  return (h >>> 0).toString(36);
}
function titleOf(f) {
  if (f.title && f.title.trim()) return f.title.trim();
  const t = f.claim.replace(/\s+/g, " ").trim().slice(0, 80);
  return t;
}
function sourcesLine(f, dreamId) {
  const bits = [`captured from ${f.source || "transcript (unnamed)"}`, `dream ${dreamId}`];
  if (f.confidence) bits.push(`confidence ${f.confidence}`);
  return `- ${bits.join(", ")}`;
}
function renderNewPage(f, category, title, hash, opts) {
  const description = f.claim.replace(/\s+/g, " ").trim().slice(0, 140);
  const lines = [
    "---",
    `title: ${title}`,
    `description: ${description}`,
    `type: ${category}`,
    `created: ${opts.date}`,
    `updated: ${opts.date}`,
    "tags: []",
    "related: []",
    // explicit empty = authoritative (body links are NOT scraped)
    "provenance: untrusted-derived",
    "origin: dream-summarizer",
    `fact_hash: ${hash}`,
    "---",
    "",
    `# ${title}`,
    "",
    f.claim.trim(),
    ""
  ];
  if (f.evidence && f.evidence.trim()) lines.push(`**Evidence:** ${f.evidence.trim()}`, "");
  lines.push("## Sources", "", sourcesLine(f, opts.dreamId), "");
  return lines.join("\n");
}
async function writeAtomic(path, content) {
  const tmp = `${path}.tmp.${process.pid}`;
  try {
    await fs.writeFile(tmp, content);
    await fs.rename(tmp, path);
  } catch (err) {
    await fs.unlink(tmp).catch(() => {
    });
    throw err;
  }
}
function appendToUntrustedSection(content, bullet) {
  const body = content.replace(/\s+$/, "");
  const at = body.indexOf(UNTRUSTED_SECTION);
  if (at === -1) return `${body}

${UNTRUSTED_SECTION}

${bullet}
`;
  const afterHeading = at + UNTRUSTED_SECTION.length;
  const rest = body.slice(afterHeading);
  const nextHeading = rest.search(/\n#{1,2} /);
  const nextGenerated = rest.search(/\n<!--\s*(graph|theme|ai):begin/);
  const candidates = [nextHeading, nextGenerated].filter((i) => i !== -1);
  const cut = candidates.length ? afterHeading + Math.min(...candidates) : body.length;
  return `${body.slice(0, cut).replace(/\s+$/, "")}
${bullet}
${body.slice(cut).replace(/^\n+/, "\n")}`.replace(/\s+$/, "") + "\n";
}
function withinWiki(wikiRoot, p) {
  const rel = relative(resolve2(wikiRoot), resolve2(p));
  return rel !== "" && !rel.startsWith("..") && !isAbsolute2(rel);
}
function bumpUpdated(content, date) {
  const fm = matchFrontmatter(content);
  if (!fm) return content;
  const newFm = fm.fm.replace(/^updated:.*$/m, `updated: ${date}`);
  return `---
${newFm}
---
${fm.body}`;
}
async function applyCandidates(stagingRoot, facts, opts) {
  const report = { added: [], updated: [], skipped: [] };
  const wikiRoot = join(stagingRoot, "wiki");
  const relationFacts = [];
  for (const f of facts) {
    const category = KIND_TO_CATEGORY[f.kind];
    if (f.kind === "relation") {
      relationFacts.push(f);
      continue;
    }
    if (!category) {
      report.skipped.push({ kind: f.kind, reason: `kind '${f.kind}' is not writer-applied \u2014 DROPPED this run (no consumer yet: preferences need the persona-rules lane, relations the live maintainer's edge writer)` });
      continue;
    }
    const title = titleOf(f);
    if (!title) {
      report.skipped.push({ kind: f.kind, reason: "empty title/claim" });
      continue;
    }
    const hash = factHash(f);
    let target = null;
    const catDir = join(wikiRoot, category);
    let pages = [];
    try {
      pages = (await fs.readdir(catDir)).filter((n) => n.endsWith(".md") && n !== "index.md").sort();
    } catch {
      pages = [];
    }
    for (const page of pages) {
      const slug2 = page.slice(0, -3);
      const p = join(catDir, page);
      let head = "";
      try {
        head = (await fs.readFile(p, "utf-8")).slice(0, 600);
      } catch {
        continue;
      }
      const pageTitle = (head.match(/^title:\s*(.+)$/m)?.[1] || slug2).replace(/^["']|["']$/g, "").trim();
      if (isFoldInMatch(title, f.claim, slug2, pageTitle)) {
        target = resolve2(p);
        break;
      }
    }
    if (target && !withinWiki(wikiRoot, target)) {
      report.skipped.push({ kind: f.kind, reason: `resolved target escapes staging wiki: ${target}` });
      continue;
    }
    if (target) {
      const content = await fs.readFile(target, "utf-8");
      if (content.includes(`(fact:${hash})`) || content.includes(`fact_hash: ${hash}`)) {
        report.skipped.push({ kind: f.kind, reason: `duplicate fact ${hash} (idempotent)` });
        continue;
      }
      const bullet = `- (fact:${hash}) ${f.claim.trim()}${f.evidence ? ` \u2014 evidence: ${f.evidence.trim()}` : ""} (${sourcesLine(f, opts.dreamId).slice(2)})`;
      await writeAtomic(target, bumpUpdated(appendToUntrustedSection(content, bullet), opts.date));
      report.updated.push(relative(wikiRoot, target).replace(/\\/g, "/"));
      continue;
    }
    let slug = slugify(title);
    try {
      validateSlug(slug);
      let path = assertWithin(wikiRoot, category, `${slug}.md`);
      let existing = null;
      try {
        existing = await fs.readFile(path, "utf-8");
      } catch {
      }
      if (existing !== null) {
        if (existing.includes(`fact_hash: ${hash}`) || existing.includes(`(fact:${hash})`)) {
          report.skipped.push({ kind: f.kind, reason: `duplicate fact ${hash} (idempotent)` });
          continue;
        }
        slug = `${slug}-${hash}`;
        validateSlug(slug);
        path = assertWithin(wikiRoot, category, `${slug}.md`);
        try {
          const clash = await fs.readFile(path, "utf-8");
          if (clash.includes(`fact_hash: ${hash}`)) {
            report.skipped.push({ kind: f.kind, reason: `duplicate fact ${hash} (idempotent)` });
            continue;
          }
        } catch {
        }
      }
      await fs.mkdir(join(wikiRoot, category), { recursive: true });
      await writeAtomic(path, renderNewPage(f, category, title, hash, opts));
      report.added.push(`${category}/${slug}.md`);
    } catch (err) {
      if (err instanceof PathGuardError) {
        report.skipped.push({ kind: f.kind, reason: `path guard rejected slug '${slug}': ${err.message}` });
      } else {
        throw err;
      }
    }
  }
  if (relationFacts.length) {
    const slugsByCat = /* @__PURE__ */ new Map();
    for (const cat of CONTENT_CATEGORIES) {
      const dir = join(wikiRoot, cat);
      let names = [];
      try {
        names = (await fs.readdir(dir)).filter((n) => n.endsWith(".md") && n !== "index.md").sort();
      } catch {
        continue;
      }
      const entries = [];
      for (const n of names) {
        let head = "";
        try {
          head = (await fs.readFile(join(dir, n), "utf-8")).slice(0, 400);
        } catch {
          continue;
        }
        const slug = n.slice(0, -3);
        entries.push({ slug, title: (head.match(/^title:\s*(.+)$/m)?.[1] || slug).replace(/^["']|["']$/g, "").trim() });
      }
      slugsByCat.set(cat, entries);
    }
    const all = [...slugsByCat.values()].flat();
    const resolveHint = (hint) => {
      const want = slugify(hint);
      if (all.some((e) => e.slug === want)) return want;
      const ht = titleTokens(hint);
      if (!ht.length) return null;
      const hits = all.filter((e) => {
        const t = titleTokens(e.title);
        return t.length > 0 && t.every((x) => ht.includes(x));
      });
      return hits.length === 1 ? hits[0].slug : null;
    };
    const edges = [];
    const seen = /* @__PURE__ */ new Set();
    for (const f of relationFacts) {
      const from = resolveHint(f.from_hint || "");
      const to = resolveHint(f.to_hint || "");
      if (!from || !to) {
        report.skipped.push({ kind: f.kind, reason: `relation endpoint unresolved (from='${f.from_hint}' to='${f.to_hint}') \u2014 no edge proposed` });
        continue;
      }
      if (from === to) {
        report.skipped.push({ kind: f.kind, reason: `relation is a self-loop on '${from}'` });
        continue;
      }
      const key = `${from}|${f.rel}|${to}`;
      if (seen.has(key)) {
        report.skipped.push({ kind: f.kind, reason: `duplicate relation ${key} (idempotent)` });
        continue;
      }
      seen.add(key);
      edges.push({ from, to, type: f.rel || "relates", confidence: "medium" });
    }
    if (edges.length) report.edges = edges.sort((a, b) => `${a.from}|${a.type}|${a.to}`.localeCompare(`${b.from}|${b.type}|${b.to}`));
  }
  return report;
}
var TITLE_STOP, UNTRUSTED_SECTION;
var init_consolidate_writer = __esm({
  "src/tools/consolidate-writer.ts"() {
    "use strict";
    init_candidate_facts();
    init_kb_schema2();
    init_path_guard();
    init_raw_inbox();
    init_frontmatter();
    TITLE_STOP = /* @__PURE__ */ new Set(["the", "a", "an", "of", "and", "or", "to", "for", "in", "on", "is", "are", "was", "were", "be", "it", "its", "this", "that", "with", "by", "as", "at", "from"]);
    UNTRUSTED_SECTION = "## Candidate facts (untrusted)";
  }
});

// src/tools/consolidate-writer-cli.ts
init_path_guard();
import { promises as fs2 } from "fs";
import { join as join2 } from "path";
async function main() {
  const idx = process.argv.indexOf("--dream-dir");
  const dreamDir = cleanEnvPath(idx > -1 ? process.argv[idx + 1] : "");
  if (!dreamDir) {
    process.stderr.write("usage: consolidate-writer-cli --dream-dir <abs>\n");
    return 2;
  }
  process.env.SECOND_BRAIN_DISABLE_EMBEDDINGS = "1";
  process.env.SB_BRAIN_DIR = join2(dreamDir, ".cw-scratch");
  await fs2.mkdir(process.env.SB_BRAIN_DIR, { recursive: true });
  const { validateCandidateFacts: validateCandidateFacts2 } = await Promise.resolve().then(() => (init_candidate_facts(), candidate_facts_exports));
  const { applyCandidates: applyCandidates2 } = await Promise.resolve().then(() => (init_consolidate_writer(), consolidate_writer_exports));
  const stagingRoot = join2(dreamDir, "staging");
  try {
    await fs2.access(join2(stagingRoot, "wiki"));
  } catch {
    process.stderr.write(`consolidate-writer: no staging wiki under ${stagingRoot}
`);
    return 1;
  }
  let rawText;
  try {
    rawText = await fs2.readFile(join2(dreamDir, "candidate-facts.json"), "utf-8");
  } catch {
    process.stdout.write(JSON.stringify({ added: [], updated: [], skipped: [], rejected: 0, note: "no candidates" }) + "\n");
    return 0;
  }
  let raw;
  try {
    raw = JSON.parse(rawText);
  } catch (err) {
    process.stderr.write(`consolidate-writer: candidate-facts.json is not valid JSON: ${err instanceof Error ? err.message : String(err)}
`);
    return 1;
  }
  const { facts, rejected } = validateCandidateFacts2(raw);
  for (const r of rejected) process.stderr.write(`consolidate-writer: rejected fact[${r.index}]: ${r.reason}
`);
  const base = dreamDir.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || "";
  let date = "";
  const m = base.match(/^drm_(\d{4})(\d{2})(\d{2})T/);
  if (m) date = `${m[1]}-${m[2]}-${m[3]}`;
  if (!date) {
    try {
      const st = JSON.parse(await fs2.readFile(join2(dreamDir, "status.json"), "utf-8"));
      if (typeof st.created_at === "string") date = st.created_at.slice(0, 10);
    } catch {
    }
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    process.stderr.write(`consolidate-writer: cannot derive a dream date from '${base}' or status.json
`);
    return 1;
  }
  const report = await applyCandidates2(stagingRoot, facts, { dreamId: base, date });
  const edgeDoc = JSON.stringify({ relations: report.edges ?? [] }) + "\n";
  const edgeTmp = join2(stagingRoot, `proposed-edges.json.tmp.${process.pid}`);
  try {
    await fs2.writeFile(edgeTmp, edgeDoc);
    await fs2.rename(edgeTmp, join2(stagingRoot, "proposed-edges.json"));
  } catch (err) {
    await fs2.unlink(edgeTmp).catch(() => {
    });
    process.stderr.write(`consolidate-writer: could not write proposed-edges.json: ${err instanceof Error ? err.message : String(err)}
`);
    return 1;
  }
  process.stdout.write(JSON.stringify({ ...report, rejected: rejected.length }) + "\n");
  return 0;
}
main().then(
  (code) => process.exit(code),
  (err) => {
    process.stderr.write(`consolidate-writer: ${err instanceof Error ? err.stack || err.message : String(err)}
`);
    process.exit(1);
  }
);
