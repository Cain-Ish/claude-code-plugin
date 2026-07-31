// src/tools/graph-cluster-cli.ts
import { promises as fs2 } from "fs";
import { join as join3, basename } from "path";

// src/tools/graph-cluster.ts
function buildAdjacency(pages) {
  const known = new Set(pages.map((p) => p.slug));
  const adj = /* @__PURE__ */ new Map();
  const ensure = (s) => {
    let x = adj.get(s);
    if (!x) {
      x = /* @__PURE__ */ new Set();
      adj.set(s, x);
    }
    return x;
  };
  for (const p of pages) {
    ensure(p.slug);
    for (const n of /* @__PURE__ */ new Set([...p.related ?? [], ...p.bodyLinks ?? []])) {
      if (n === p.slug || !known.has(n)) continue;
      ensure(p.slug).add(n);
      ensure(n).add(p.slug);
    }
  }
  return adj;
}
function normalize(labels) {
  const groups = /* @__PURE__ */ new Map();
  for (const [node, lab] of labels) {
    let g = groups.get(lab);
    if (!g) {
      g = [];
      groups.set(lab, g);
    }
    g.push(node);
  }
  const out = /* @__PURE__ */ new Map();
  for (const members of groups.values()) {
    const id = [...members].sort()[0];
    for (const m of members) out.set(m, id);
  }
  return out;
}
function labelPropagate(adj, opts = {}) {
  const maxIter = opts.maxIter ?? 20;
  const nodes = [...adj.keys()].sort();
  let labels = new Map(nodes.map((n) => [n, n]));
  for (let iter = 0; iter < maxIter; iter++) {
    const next = /* @__PURE__ */ new Map();
    let changed = false;
    for (const node of nodes) {
      const own = labels.get(node);
      const nbrs = adj.get(node);
      if (nbrs.size === 0) {
        next.set(node, own);
        continue;
      }
      const tally = /* @__PURE__ */ new Map();
      for (const nb of nbrs) {
        const l = labels.get(nb);
        tally.set(l, (tally.get(l) ?? 0) + 1);
      }
      const max = Math.max(...tally.values());
      const tied = [...tally.entries()].filter(([, c]) => c === max).map(([l]) => l);
      const chosen = tied.includes(own) ? own : tied.sort()[0];
      next.set(node, chosen);
      if (chosen !== own) changed = true;
    }
    labels = next;
    if (!changed) break;
  }
  return normalize(labels);
}
function clusters(labels, opts) {
  const groups = /* @__PURE__ */ new Map();
  for (const [node, lab] of labels) {
    let g = groups.get(lab);
    if (!g) {
      g = [];
      groups.set(lab, g);
    }
    g.push(node);
  }
  const out = [];
  for (const [id, members] of groups) {
    if (members.length >= opts.minSize) out.push({ id, members: [...members].sort() });
  }
  return out.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}
function djb2(s) {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h ^ s.charCodeAt(i)) >>> 0;
  return h.toString(36);
}
function memberHash(sortedMembers, contentHashBySlug) {
  const basis = sortedMembers.join("|") + "::" + sortedMembers.map((s) => contentHashBySlug[s] ?? "").join("|");
  return djb2(basis);
}

// src/brain-paths.ts
import { join, isAbsolute } from "path";
import { homedir } from "os";

// src/path-guard.ts
function cleanEnvPath(s) {
  return (s ?? "").replace(/[\r\n]/g, "");
}

// src/brain-paths.ts
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
var AI_BLOCK_RE_G = new RegExp(AI_BLOCK_RE.source, "g");

// src/tools/frontmatter.ts
function matchFrontmatter(content) {
  const m = content.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  return m ? { fm: m[1], body: m[2] } : null;
}
function stripFrontmatter(content) {
  const m = matchFrontmatter(content);
  return m ? m.body : content;
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

// src/tools/graph-cluster-cli.ts
function resolveWikiDir(argv) {
  if (argv[0] === "--knowledge-dir" && argv[1]) return join3(argv[1], "wiki");
  if (argv[0]) return argv[0];
  const kd = resolveKnowledgeDir();
  return join3(kd, "wiki");
}
function frontmatter(content) {
  return matchFrontmatter(content)?.fm ?? "";
}
function links(text) {
  return [...text.matchAll(/\[\[([^\]]+)\]\]/g)].map((m) => m[1].split("|")[0].trim()).filter(Boolean);
}
function relatedFrom(fm) {
  const line = fm.split("\n").find((l) => /^related:/.test(l));
  if (!line) return [];
  const wl = links(line);
  if (wl.length) return wl;
  const m = line.match(/^related:\s*\[(.*)\]\s*$/);
  if (!m) return [];
  return m[1].split(",").map((s) => s.trim().replace(/^["']|["']$/g, "")).filter((s) => /^[a-z0-9][a-z0-9-]*$/i.test(s));
}
async function main() {
  const wikiDir = resolveWikiDir(process.argv.slice(2));
  const minSize = parseInt(process.env.SB_SUMMARIZE_MIN_CLUSTER ?? "4", 10) || 4;
  const files = await walkWiki(wikiDir, { skipHidden: true, skipDirs: ["projects", "themes"] });
  const pages = [];
  const contentHash = {};
  for (const f of files) {
    let content = "";
    try {
      content = await fs2.readFile(f, "utf-8");
    } catch {
      continue;
    }
    if (!content.trim()) continue;
    const slug = basename(f, ".md");
    const fm = frontmatter(content);
    if (/^generated:[ \t]*true\b/m.test(fm)) continue;
    const body = stripFrontmatter(content);
    pages.push({ slug, related: relatedFrom(fm), bodyLinks: [...new Set(links(body))] });
    contentHash[slug] = djb2(content);
  }
  const maxPages = parseInt(process.env.SB_SUMMARIZE_MAX_PAGES ?? "8", 10) || 8;
  const labels = labelPropagate(buildAdjacency(pages));
  const capped = [...clusters(labels, { minSize })].sort((a, b) => b.members.length - a.members.length || (a.id < b.id ? -1 : 1)).slice(0, maxPages).sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  const out = capped.map((c) => ({
    id: c.id,
    members: c.members,
    member_hash: memberHash(c.members, contentHash)
  }));
  process.stdout.write(JSON.stringify(out) + "\n");
}
main().catch((e) => {
  process.stderr.write(String(e) + "\n");
  process.exit(1);
});
