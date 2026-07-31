// src/tools/wiki-redundancy-cli.ts
import { promises as fs2 } from "fs";
import { join as join3, basename, dirname } from "path";

// src/tools/graph-cluster.ts
function djb2(s) {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h ^ s.charCodeAt(i)) >>> 0;
  return h.toString(36);
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
    _comment: "Stage A <-> Stage B contract for the P6 quarantined consolidation split. json_schema is passed VERBATIM to the Stage A summarizer spawn (claude -p --json-schema, validator-enforced from CLI 2.1.205) by scripts/maintain-llm-drain.sh (jq -c .candidate_facts.json_schema). The Stage B writer (mcp/src/tools/candidate-facts.ts) validates against the SAME object, deriving the kind vocabulary and byte caps from it - never a second copy. kind_to_category maps writable kinds to wiki categories; kinds absent from the map (preference, relation) are SKIPPED by the writer with a logged reason: preferences route to attended persona lanes, relations to the live maintainer (edge writes are live-maintainer-only).",
    kind_to_category: { decision: "decisions", learning: "learnings", entity: "entities", issue: "issues" },
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
function stripAiBlock(text) {
  return text.replace(AI_BLOCK_RE_G, "");
}

// src/tools/sanitize.ts
var INVISIBLE_RE = /[\u{200B}\u{2060}\u{FEFF}\u{E0000}-\u{E007F}]/gu;
function stripInvisible(s) {
  return s.replace(INVISIBLE_RE, "");
}

// src/tools/frontmatter.ts
function matchFrontmatter(content) {
  const m = content.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  return m ? { fm: m[1], body: m[2] } : null;
}
function stripFrontmatter(content) {
  const m = matchFrontmatter(content);
  return m ? m.body : content;
}

// src/tools/minhash.ts
var SHINGLE_K = 3;
var NUM_HASHES = 128;
var EMPTY_HASH = 4294967295;
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
function proseTokens(content) {
  let t = stripAiBlock(stripInvisible(content));
  t = stripFrontmatter(t);
  t = t.replace(/<!--\s*theme:begin[\s\S]*?theme:end\s*-->/g, "");
  t = t.replace(/<!--\s*graph:begin[\s\S]*?graph:end\s*-->/g, "");
  t = t.replace(/\[\[([^\]]+)\]\]/g, " ");
  return t.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
}
function shingles(content, k = SHINGLE_K) {
  const w = proseTokens(content);
  const set = /* @__PURE__ */ new Set();
  if (w.length === 0) return set;
  if (w.length < k) {
    set.add(w.join(" "));
    return set;
  }
  for (let i = 0; i + k <= w.length; i++) set.add(w.slice(i, i + k).join(" "));
  return set;
}
function baseHash(shingle) {
  return parseInt(djb2(shingle), 36) >>> 0;
}
function minhashSignature(shingleSet) {
  const sig = new Uint32Array(NUM_HASHES).fill(EMPTY_HASH);
  for (const sh of shingleSet) {
    const base = baseHash(sh);
    for (let i = 0; i < NUM_HASHES; i++) {
      const h = Math.imul(A[i], base) + B[i] >>> 0;
      if (h < sig[i]) sig[i] = h;
    }
  }
  return sig;
}
function jaccardEstimate(a, b) {
  const n = Math.min(a.length, b.length);
  if (n === 0) return 0;
  let eq = 0;
  for (let i = 0; i < n; i++) if (a[i] === b[i]) eq++;
  return eq / n;
}
function isEmptySignature(sig) {
  if (sig.length === 0) return true;
  for (let i = 0; i < sig.length; i++) if (sig[i] !== EMPTY_HASH) return false;
  return true;
}
function nearDuplicatePairs(pages, threshold = 0.7) {
  const real = pages.filter((p) => !isEmptySignature(p.sig));
  const out = [];
  for (let i = 0; i < real.length; i++) {
    for (let j = i + 1; j < real.length; j++) {
      const sim = jaccardEstimate(real[i].sig, real[j].sig);
      if (sim < threshold) continue;
      const [p, q] = real[i].slug <= real[j].slug ? [real[i], real[j]] : [real[j], real[i]];
      out.push({ a: p.slug, b: q.slug, sim: Math.round(sim * 1e3) / 1e3, a_cat: p.cat, b_cat: q.cat });
    }
  }
  out.sort((x, y) => y.sim - x.sim || (x.a < y.a ? -1 : x.a > y.a ? 1 : x.b < y.b ? -1 : x.b > y.b ? 1 : 0));
  return out;
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

// src/tools/wiki-redundancy-cli.ts
function resolveWikiDir(argv) {
  if (argv[0] === "--knowledge-dir" && argv[1]) return join3(argv[1], "wiki");
  if (argv[0]) return argv[0];
  return join3(resolveKnowledgeDir(), "wiki");
}
function envFloat(name, def, lo, hi) {
  const v = parseFloat(process.env[name] ?? "");
  return Number.isFinite(v) && v >= lo && v <= hi ? v : def;
}
async function main() {
  const wikiDir = resolveWikiDir(process.argv.slice(2));
  const threshold = envFloat("SB_REDUNDANCY_THRESHOLD", 0.7, 0.01, 1);
  const mp = parseInt(process.env.SB_REDUNDANCY_MAX_PAIRS ?? "", 10);
  const maxPairs = Math.max(1, Number.isNaN(mp) ? 50 : mp);
  const files = await walkWiki(wikiDir, { skipHidden: true, skipDirs: ["projects", "themes"] });
  const pages = [];
  for (const f of files) {
    let content = "";
    try {
      content = await fs2.readFile(f, "utf-8");
    } catch {
      continue;
    }
    if (!content.trim()) continue;
    const sh = shingles(content);
    if (sh.size === 0) continue;
    pages.push({ slug: basename(f, ".md"), cat: basename(dirname(f)), sig: minhashSignature(sh) });
  }
  const pairs = nearDuplicatePairs(pages, threshold).slice(0, maxPairs);
  process.stdout.write(JSON.stringify(pairs) + "\n");
}
main().catch((e) => {
  process.stderr.write(String(e) + "\n");
  process.exit(1);
});
