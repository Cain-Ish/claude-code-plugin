// src/tools/ai-block.ts
var AI_BLOCK_SCHEMAS = {
  learnings: { fields: ["claim", "trigger", "action", "scope", "evidence", "supersedes"], required: ["claim", "action"] },
  decisions: { fields: ["context", "choice", "alternatives", "rationale", "status", "supersedes"], required: ["choice"] },
  entities: { fields: ["identity", "current_state", "depends_on", "owns", "status"], required: ["identity"] },
  issues: { fields: ["symptom", "cause", "fix", "severity", "status"], required: ["symptom", "status"] },
  concepts: { fields: ["problem", "solution", "where_applied", "tradeoffs"], required: ["problem", "solution"] },
  security: { fields: ["threat", "mitigation", "scope", "status"], required: ["threat", "mitigation"] }
};
var AI_BLOCK_RENDER_BEGIN = "<!-- ai:begin (authored \u2014 flat YAML, see ai-block schema) -->";
var AI_BLOCK_RENDER_END = "<!-- ai:end -->";
function renderAiBlock(type, block) {
  const schema = AI_BLOCK_SCHEMAS[type];
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
