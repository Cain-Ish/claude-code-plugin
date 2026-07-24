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
var AI_BLOCK_RE_G = new RegExp(AI_BLOCK_RE.source, "g");
var AI_BLOCK_RENDER_BEGIN = "<!-- ai:begin (authored \u2014 flat YAML, see ai-block schema) -->";
var AI_BLOCK_RENDER_END = "<!-- ai:end -->";
function renderAiBlock(type, block) {
  const schema = schemaFor(type);
  if (!schema) return "";
  const lines = [];
  for (const f of schema.fields) {
    const v = (block[f] ?? "").toString().replace(/<!--|-->|ai:(begin|end)/gi, " ").replace(/\s+/g, " ").trim();
    if (v) lines.push(`${f}: ${v}`);
  }
  if (lines.length === 0) return "";
  return [AI_BLOCK_RENDER_BEGIN, ...lines, AI_BLOCK_RENDER_END].join("\n");
}

// src/tools/ai-block-render-cli.ts
var input = "";
process.stdin.setEncoding("utf-8");
for await (const chunk of process.stdin) input += chunk;
try {
  const { type, block } = JSON.parse(input || "{}");
  if (type && block && typeof block === "object") {
    const out = renderAiBlock(String(type), block);
    if (out) process.stdout.write(out + "\n");
  }
} catch {
}
