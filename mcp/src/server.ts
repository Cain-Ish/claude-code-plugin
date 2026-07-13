import { McpServer, type ToolCallback } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "fs";
import path from "path";
import { EDGE_TYPES, type EdgeType } from "./tools/graph-store.js";
import { pinToUser } from "./tools/pin-to-user.js";
import { pinToProject } from "./tools/pin-to-project.js";
import { archiveToWiki } from "./tools/archive-to-wiki.js";
import { knowledgeSearch } from "./tools/knowledge-search.js";
import { knowledgeFetch } from "./tools/knowledge-fetch.js";
import { knowledgeReindex } from "./tools/knowledge-reindex.js";
import { knowledgeValidate } from "./tools/knowledge-validate.js";
import { dreamCreate, dreamStatus, dreamList, dreamAccept, dreamDiscard, dreamCancel } from "./tools/dream.js";
import { episodicSearch, episodicRead, assertTranscriptPath, withActiveScope } from "./tools/episodic-search.js";
import { personaThink } from "./tools/persona-think.js";
import { personaStats } from "./tools/persona-stats.js";
import { personaDismiss } from "./tools/persona-dismiss.js";
import { capList, egressBudgetTokens } from "./tools/egress-budget.js";
import { knowledgeRelate } from "./tools/knowledge-relate.js";
import { knowledgeNeighbors } from "./tools/knowledge-neighbors.js";
import { codeMap } from "./tools/codemap/code-map.js";
import { codeNeighbors } from "./tools/codemap/code-neighbors.js";
import { resolveActiveSlug as resolveActiveSlugFromDir } from "./tools/project-dir.js";
import { resolveBrainDir, resolveKnowledgeDir } from "./brain-paths.js";
import { walkWiki } from "./tools/walk-wiki.js";
import { guardDestructive } from "./nested-spawn-guard.js";

// Both dirs resolve through brain-paths.ts ONLY — server.ts used to carry a local
// resolveKnowledgeDir with the OPPOSITE precedence (env over plugin option) to the
// canonical resolver, so the server and the tools it called could read two
// different wikis. brain-paths owns the precedence, the CRLF stripping, the
// unexpanded-`${...}` rejection, and the `~` expansion.
const KNOWLEDGE_DIR = resolveKnowledgeDir();
const BRAIN_DIR = resolveBrainDir();

function resolveActiveSlug(): string | undefined {
  // Delegate to the shared resolver: the per-session project dir (CLAUDE_PROJECT_DIR,
  // else cwd) is authoritative; the shared .active-session-slug pin is only a
  // last-resort fallback — a concurrent session can no longer use it to hijack scoping.
  return resolveActiveSlugFromDir(BRAIN_DIR);
}

const server = new McpServer(
  { name: "knowledge-base", version: "2.9.0" },
  {
    capabilities: { logging: {} },
    instructions: "BM25-scored search over the local knowledge base. Use knowledge_search to find relevant wiki pages (searches full content with field-weighted scoring), knowledge_reindex to regenerate the wiki index.md catalog (also runs validation with autofix), knowledge_validate to check wiki health (broken links, orphans, duplicates, session-narrative pages), knowledge_stats for an overview of wiki size and categories, pin_to_user to record a user-level preference, pin_to_project to append blockers/decisions to a project's PROJECT.md, and archive_to_wiki to graduate a [resolved] entry from a project file into the wiki. Dream tools: dream_create to start a background consolidation job (snapshots wiki + selects transcripts), dream_status to check progress, dream_list to see all dreams, dream_accept to apply a completed dream's changes, dream_discard to reject changes, and dream_cancel to stop a running dream. Episodic memory: episodic_search to search past conversation transcripts (hybrid vector + text, multi-concept AND), episodic_read to read a specific transcript section. Relational graph: knowledge_relate to assert/invalidate a typed bi-temporal relationship (requires|affects|relates|part_of|supersedes) between two pages, and knowledge_neighbors to walk a page's dependency neighbourhood (multi-hop, directional, point-in-time via as_of).",
  }
);

function categorizeFile(filePath: string): string {
  const rel = path.relative(path.join(KNOWLEDGE_DIR, "wiki"), filePath);
  const parts = rel.split(path.sep);
  return parts.length > 1 ? parts[0] : "uncategorized";
}

// --- Tool registration helper ---

type JsonToolResult = { content: { type: "text"; text: string }[]; isError?: boolean };
type JsonToolHandler<Shape extends z.ZodRawShape> =
  (args: z.objectOutputType<Shape, z.ZodTypeAny>) => Promise<JsonToolResult>;

/** The single registration path for every tool: owns the try/catch, the ONE
 *  error grammar (`<tool> error: <message>` + isError), and serialization
 *  (string results pass through as text, objects are JSON.stringify'd).
 *  `wrap` lets destructive tools keep their literal guardDestructive("<name>")
 *  wrapper (nested-spawn-guard.test.ts Part C greps for exactly that). */
function registerJsonTool<Shape extends z.ZodRawShape>(
  name: string,
  description: string,
  inputSchema: Shape,
  fn: (args: z.objectOutputType<Shape, z.ZodTypeAny>) => Promise<unknown>,
  wrap: (h: JsonToolHandler<Shape>) => JsonToolHandler<Shape> = (h) => h,
): void {
  const handler: JsonToolHandler<Shape> = async (args) => {
    try {
      const result = await fn(args);
      return { content: [{ type: "text" as const, text: typeof result === "string" ? result : JSON.stringify(result) }] };
    } catch (error) {
      return {
        content: [{ type: "text" as const, text: `${name} error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  };
  // ToolCallback<Shape> is a conditional type over the still-generic Shape, so
  // TS cannot resolve assignability here; the handler matches its resolved
  // (args, extra) => Promise<CallToolResult> form for every concrete call site.
  server.registerTool(name, { description, inputSchema }, wrap(handler) as unknown as ToolCallback<Shape>);
}

// --- Tools ---

registerJsonTool(
  "knowledge_search",
  "Hybrid search across the knowledge base wiki: BM25 (title 3x, description 2x, tags 2x, ai-block 1.5x, body 1x) fused with ONNX embeddings via RRF when available, plus a 90-day recency boost, stub down-ranking, and project-scoped tiering; a capped graph-edge boost is opt-in via SB_GRAPH_RANKING_BOOST=1 (off by default). Returns top 8 candidates with path, raw score, score_norm (0..1, comparable across modes), tier (when project scoping is active), and snippet. Result carries degraded:'bm25-only' when embeddings are unavailable.",
  {
    query: z.string().describe("Search query — tokenized on lowercase alphanumerics, date tokens filtered out, matched via BM25 scoring."),
    scope: z.string().optional().describe("Restrict to a single wiki subdirectory (e.g. 'entities', 'learnings'). Omit to search all."),
  },
  ({ query, scope }) => knowledgeSearch({ query, scope, knowledgeDir: KNOWLEDGE_DIR, brainDir: BRAIN_DIR, projectSlug: resolveActiveSlug() })
);

registerJsonTool(
  "knowledge_fetch",
  "Fetch a wiki page at a chosen detail tier (progressive disclosure). tier: 'gist' (one-line), 'skeleton' (gist + headings), 'block' (the machine-first ai-block shared-intermediate — claim/action/etc — or the summary if none), 'summary' (the page's ## Summary section, or skeleton if none yet), 'full' (body, capped to the egress budget). Always returns a source pointer so you can escalate to the full page only when needed. Prefer this over reading the raw file for large pages.",
  {
    slug: z.string().describe("The page slug (filename without .md), e.g. from a knowledge_search result path."),
    tier: z.enum(["gist", "skeleton", "block", "summary", "full"]).optional().describe("Detail level. Default 'gist'."),
  },
  ({ slug, tier }) => knowledgeFetch({ slug, tier, knowledgeDir: KNOWLEDGE_DIR })
);

registerJsonTool(
  "pin_to_user",
  "Pin a preference to USER.md. Use only when the user explicitly says 'pin to my second-brain' or runs /second-brain:pin. Plain 'remember this' should write to Claude Code's built-in auto-memory, not here.",
  { text: z.string() },
  ({ text }) => pinToUser({ text }),
  (h) => guardDestructive("pin_to_user", h)
);

registerJsonTool(
  "pin_to_project",
  "Append an entry to the active project's PROJECT.md. Section must be 'blockers' or 'decisions'.",
  {
    text: z.string(),
    slug: z.string(),
    section: z.enum(["blockers", "decisions"]),
  },
  ({ text, slug, section }) => pinToProject({ text, slug, section }),
  (h) => guardDestructive("pin_to_project", h)
);

registerJsonTool(
  "archive_to_wiki",
  "Archive a [resolved] entry from PROJECT.md to ~/knowledge/wiki/<category>/<slug>/. Leaves a back-reference line in PROJECT.md.",
  {
    slug: z.string(),
    sourceSection: z.enum(["blockers", "decisions"]),
    entryText: z.string(),
    targetCategory: z.enum(["issues", "decisions"]),
  },
  (input) => archiveToWiki(input),
  (h) => guardDestructive("archive_to_wiki", h)
);

registerJsonTool(
  "knowledge_stats",
  "Get knowledge base statistics: total wiki files, files per category, and total bytes. Reads the wiki tree directly — no separate index to maintain.",
  {},
  async () => {
    const wikiDir = path.join(KNOWLEDGE_DIR, "wiki");

    if (!fs.existsSync(wikiDir)) {
      return [
        `# Knowledge Base Stats`,
        ``,
        `- **Knowledge dir**: ${KNOWLEDGE_DIR}`,
        `- **Wiki directory**: not present (run the setup skill to create it)`,
      ].join("\n");
    }

    const files = await walkWiki(wikiDir, { includeIndex: true, skipHidden: true });
    const categories: Record<string, { count: number; bytes: number }> = {};
    let totalBytes = 0;

    for (const file of files) {
      const cat = categorizeFile(file);
      let size = 0;
      try {
        size = fs.statSync(file).size;
      } catch {
        // File vanished between walk and stat — skip silently.
        continue;
      }
      totalBytes += size;
      if (!categories[cat]) categories[cat] = { count: 0, bytes: 0 };
      categories[cat].count += 1;
      categories[cat].bytes += size;
    }

    const catLines = Object.entries(categories)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([cat, { count, bytes }]) => `  - ${cat}: ${count} pages, ${bytes} bytes`)
      .join("\n");

    return [
      `# Knowledge Base Stats`,
      ``,
      `- **Total wiki files**: ${files.length}`,
      `- **Total bytes**: ${totalBytes}`,
      `- **Knowledge dir**: ${KNOWLEDGE_DIR}`,
      ``,
      `## Categories`,
      catLines || "  (no pages yet)",
    ].join("\n");
  }
);

registerJsonTool(
  "knowledge_reindex",
  "Regenerate wiki/index.md — a master catalog of all wiki pages with titles, descriptions, and category counts. Call after wiki writes or when index.md is stale.",
  {},
  async () => {
    const result = await knowledgeReindex(KNOWLEDGE_DIR);
    const lines = [`Reindexed ${result.pagesIndexed} pages across ${result.categories.length} categories.`];
    if (result.validation) {
      if (result.validation.fixed > 0) lines.push(`Auto-fixed ${result.validation.fixed} issues.`);
      const remaining = result.validation.issues.filter(i => !i.autofix || i.type !== 'empty_page');
      if (remaining.length > 0) {
        lines.push(`\nValidation issues (${remaining.length}):`);
        for (const issue of remaining.slice(0, 10)) {
          lines.push(`  [${issue.severity}] ${issue.message}`);
        }
      }
    }
    return lines.join('\n');
  },
  (h) => guardDestructive("knowledge_reindex", h)
);

registerJsonTool(
  "knowledge_validate",
  "Validate knowledge base health: detect orphan files, broken wiki-links, missing frontmatter, duplicate slugs, empty pages, and root-level orphans. Report-only by default; pass {autofix:true} to mutate (DELETES empty pages, rewrites/normalizes/patches frontmatter). Returns all issues with severity and suggested fixes.",
  {
    autofix: z.boolean().optional().describe("Set true to auto-fix safe issues — DELETES empty pages and rewrites frontmatter. Default false (report-only)."),
  },
  async ({ autofix }) => {
    // Phase 3b: default to NON-DESTRUCTIVE. A casual/unattended MODEL call must
    // not silently delete "empty" pages or rewrite frontmatter — the model has to
    // opt into mutation with {autofix:true}. Internal automation (sb_validate_wiki,
    // knowledgeReindex) calls knowledgeValidate() DIRECTLY with explicit
    // {autofix:true}, so it is unaffected by this tool-surface default flip.
    const result = await knowledgeValidate(KNOWLEDGE_DIR, { autofix: autofix ?? false });
    const lines = [`Scanned ${result.pagesScanned} pages.`];
    if (result.fixed > 0) lines.push(`Auto-fixed ${result.fixed} issues.`);
    if (result.issues.length > 0) {
      lines.push(`\n${result.issues.length} issues found:`);
      for (const issue of result.issues) {
        lines.push(`  [${issue.severity}] ${issue.type}: ${issue.message}`);
      }
    } else {
      lines.push('No issues found.');
    }
    return lines.join('\n');
  },
  (h) => guardDestructive("knowledge_validate", h)
);

// --- Dream tools ---

registerJsonTool(
  "dream_create",
  "Start a new dream — async background consolidation of the knowledge base. Snapshots the wiki, selects session transcripts, and prepares for consolidation. Only one dream may be pending/running at a time.",
  {
    instructions: z.string().optional().describe("Guidance for the consolidation (max 4096 chars). E.g., 'Focus on React patterns; ignore one-off debugging notes.'"),
    transcript_filter: z.object({
      project_slug: z.string().optional().describe("Only include transcripts from this project"),
      since: z.string().optional().describe("Only include transcripts since this ISO date (YYYY-MM-DD)"),
      max_count: z.number().optional().describe("Max transcripts to include (default 50, max 100)"),
      family: z.boolean().optional().describe("Mine the whole monorepo family — the active project's root + siblings, from projects.jsonl. 'all' (project_slug) wins if both are set."),
    }).optional(),
    model: z.string().optional().describe("Model for consolidation. Default: claude-sonnet-4-6"),
  },
  (args) => dreamCreate(args),
  (h) => guardDestructive("dream_create", h)
);

registerJsonTool(
  "dream_status",
  "Get the current status of a dream by ID. Returns lifecycle state, inputs, outputs, and a diff preview if completed.",
  {
    dream_id: z.string().describe("The dream ID (e.g., drm_20260511T143022Z)"),
  },
  (args) => dreamStatus(args)
);

registerJsonTool(
  "dream_list",
  "List all dreams, newest first. Excludes archived dreams by default.",
  {
    include_archived: z.boolean().optional().describe("Include archived dreams. Default false."),
  },
  (args) => dreamList(args)
);

registerJsonTool(
  "dream_accept",
  "Accept a completed dream — applies staged wiki changes to the live knowledge base. The dream is archived after acceptance.",
  {
    dream_id: z.string().describe("The dream ID to accept"),
  },
  (args) => dreamAccept(args),
  (h) => guardDestructive("dream_accept", h)
);

registerJsonTool(
  "dream_discard",
  "Discard a dream's output without applying changes. Works on completed, failed, or canceled dreams.",
  {
    dream_id: z.string().describe("The dream ID to discard"),
  },
  (args) => dreamDiscard(args),
  (h) => guardDestructive("dream_discard", h)
);

registerJsonTool(
  "dream_cancel",
  "Cancel a pending or running dream. Sets status to 'canceled' — does not terminate a running agent process (the agent checks status.json and stops on its own).",
  {
    dream_id: z.string().describe("The dream ID to cancel"),
  },
  (args) => dreamCancel(args),
  (h) => guardDestructive("dream_cancel", h)
);

// --- Episodic memory tools ---

registerJsonTool(
  "episodic_search",
  "Search past conversation transcripts using hybrid vector + text matching. Supports single query string or array of 2-5 concepts for AND matching. Returns ranked results with similarity scores, session metadata, and file paths for follow-up reading. Result carries degraded:'text-only' when vector search is unavailable (embeddings missing) and only text matching ran.",
  {
    query: z.union([
      z.string().describe("Search query for semantic + text matching"),
      z.array(z.string()).min(2).max(5).describe("2-5 concepts — returns only exchanges matching ALL"),
    ]),
    mode: z.enum(["vector", "text", "both"]).optional().describe("Search mode. Default: 'both'"),
    limit: z.number().min(1).max(30).optional().describe("Max results. Default: 10"),
    project: z.string().optional().describe("Hard-filter to this exact project slug. Omit to default to the ACTIVE project (soft scope, so recall stays focused); pass \"all\" to deliberately search every project."),
    after: z.string().optional().describe("Only include results after this date (YYYY-MM-DD)"),
    before: z.string().optional().describe("Only include results before this date (YYYY-MM-DD)"),
  },
  async (args) => {
    const result = await episodicSearch(withActiveScope(args, resolveActiveSlug()), BRAIN_DIR);
    if (result.results.length === 0) {
      return "No matching conversations found.";
    }
    const render = (r: typeof result.results[number]) => {
      const sim = r.similarity > 0 ? ` (${Math.round(r.similarity * 100)}%)` : '';
      return [
        `### ${r.project} — ${r.date}${sim}`,
        `**User**: ${r.userSnippet}`,
        `**Assistant**: ${r.assistantSnippet}`,
        `*Session: ${r.sessionId} | Lines ${r.lineStart}-${r.lineEnd} | ${r.archivePath}*`,
      ].join('\n');
    };
    const capped = capList(result.results, render, egressBudgetTokens(), 'narrow the query or use episodic_read on a specific result');
    return capped.text;
  }
);

registerJsonTool(
  "episodic_read",
  "Read full conversation context from a specific transcript file (must be inside the second-brain transcripts directory). Use after episodic_search to get complete exchange details.",
  {
    path: z.string().describe("Absolute path to the transcript file (inside the second-brain transcripts directory)"),
    startLine: z.number().optional().describe("Start line (1-indexed). Omit to read from beginning."),
    endLine: z.number().optional().describe("End line (1-indexed). Omit to read to end."),
  },
  async (args) => {
    const safePath = assertTranscriptPath(BRAIN_DIR, args.path);
    const result = await episodicRead(safePath, args.startLine, args.endLine);
    const header = [
      `**Session**: ${result.sessionId}`,
      `**Project**: ${result.project}`,
      `**Date**: ${result.date}`,
      '---',
    ].join('\n');
    return `${header}\n${result.content}`;
  }
);

registerJsonTool(
  "persona_think",
  "Persona advisor brief. Spawn `claude -p` with Opus 4.7 (configurable via SB_PERSONA_MODEL) to produce a structured second opinion before answering a non-trivial prompt. Returns intent read, prompt enrichment, clarifying questions, relevant specialists, and risk flags. Use sparingly — Opus is expensive. Best for ambiguous prompts, design decisions, or multi-domain work where the persona's prior context matters.",
  {
    prompt: z.string().describe("The user prompt or topic to brief on."),
    context_hints: z.array(z.string()).optional().describe("Optional extra context strings to feed into the brief (e.g. relevant wiki snippets, project state)."),
  },
  (args) => personaThink({ prompt: args.prompt, context_hints: args.context_hints }, { brainDir: BRAIN_DIR })
);

registerJsonTool(
  "persona_stats",
  "Inspect the persona's current state — identity summary from persona-card.md, signal counts, installed catalog sizes, recent dismissals, today's persona spend (informational — no enforcement). Read-only.",
  {},
  () => personaStats({})
);

registerJsonTool(
  "persona_dismiss",
  "Record a dismissal: the persona's last ambient suggestion was unhelpful. Wires real dismissal-aware backoff — after SB_PERSONA_DISMISS_MAX (default 3) dismissals in the trailing window, persona-context.sh self-suppresses the per-prompt ambient injection (explicit /? Opus briefs are unaffected). Use when the user says the persona was wrong or noisy. Logged to ~/.second-brain/.persona-dismissals.jsonl.",
  {
    prompt_snippet: z.string().optional().describe("First ~200 chars of the prompt being dismissed."),
    reason: z.string().optional().describe("Why the suggestion was unhelpful."),
  },
  // Thread the server's resolved BRAIN_DIR (like knowledgeSearch/episodicSearch/personaThink):
  // the persona-context.sh dismissal-backoff gate READS $BRAIN_DIR/.persona-dismissals.jsonl, so
  // the writer MUST land in the same dir or the backoff silently never fires under a non-default
  // BRAIN_DIR (deep-review: split-path trap).
  (args) => personaDismiss({ ...args, brainDir: BRAIN_DIR }),
  (h) => guardDestructive("persona_dismiss", h)
);

// --- Relational graph tools ---

registerJsonTool(
  "knowledge_relate",
  "Assert (or invalidate) a typed, bi-temporal relationship between two wiki pages. Use when the user confirms that one thing relates to / requires / affects another, so a future session recalls it without re-explaining. types: requires | affects | relates | part_of | supersedes. Set invalidate:true with valid_to to mark a relationship no longer true (history is preserved, never deleted).",
  {
    from: z.string().describe("Source page slug (kebab-case)."),
    to: z.string().describe("Target page slug (kebab-case)."),
    type: z.enum(EDGE_TYPES as [EdgeType, ...EdgeType[]]),
    valid_from: z.string().optional().describe("Date the relationship became true (YYYY-MM-DD). Default: today."),
    valid_to: z.string().optional().describe("Date it stopped being true (YYYY-MM-DD). Required semantics with invalidate:true."),
    invalidate: z.boolean().optional().describe("Mark an existing relationship no longer valid instead of asserting one."),
    reason: z.string().optional().describe("Why (especially on invalidate)."),
  },
  (args) => knowledgeRelate({ ...args, knowledgeDir: KNOWLEDGE_DIR }),
  (h) => guardDestructive("knowledge_relate", h)
);

registerJsonTool(
  "knowledge_neighbors",
  "Walk the typed relationship graph from a page: multi-hop, time-filtered. direction 'out' = its dependencies (what it requires/affects), 'in' = its blast radius (what breaks if it changes), 'both' = default. Set as_of to a past date to reconstruct the graph as it was then. Returns edges with type, hops, score, and validity interval.",
  {
    slug: z.string().describe("The page slug to start from."),
    depth: z.number().min(1).max(4).optional().describe("Max hops. Default 2."),
    direction: z.enum(["out", "in", "both"]).optional().describe("Default 'both'."),
    edge_types: z.array(z.enum(EDGE_TYPES as [EdgeType, ...EdgeType[]])).optional(),
    as_of: z.string().optional().describe("Point-in-time (YYYY-MM-DD or ISO). Default now."),
  },
  (args) => knowledgeNeighbors({ ...args, knowledgeDir: KNOWLEDGE_DIR })
);

// --- Code-map tools (P3a orientation layer; read-only, no guardDestructive) ---

registerJsonTool(
  "code_map",
  "Return the token-capped, PageRank-ranked code-structure map for the active project (orientation: what exists / where it lives). Read-only; regenerated out-of-band on code change. Carries stale:true when the repo changed since generation. This is the CODE map — distinct from knowledge_search/knowledge_neighbors (the wiki).",
  {
    token_budget: z.number().min(200).max(8000).optional().describe("Token cap for the returned map (chars/4 estimate). Default SB_CODEMAP_TOKEN_BUDGET or 2000."),
  },
  async ({ token_budget }) => {
    const slug = resolveActiveSlug();
    if (!slug) {
      return "code_map: no active project resolvable (degenerate project dir) — nothing to map.";
    }
    const result = await codeMap({ brainDir: BRAIN_DIR, slug, tokenBudget: token_budget });
    if (result.kind === "missing") {
      return result.notice;
    }
    return result;
  }
);

registerJsonTool(
  "code_neighbors",
  "Blast-radius query over the code-structure import graph: direction 'in' = importers (what breaks if this file changes), 'out' = its dependencies. node accepts a full POSIX-relative file id ('src/a.ts'), a symbol id ('src/a.ts#foo'), or a bare basename ('server.ts' — an ambiguous basename returns all matches to pick from). This walks the CODE graph — distinct from knowledge_neighbors (the wiki graph).",
  {
    node: z.string().describe("File id, symbol id, or bare basename to start from."),
    direction: z.enum(["in", "out", "both"]).default("both").describe("'in' = importers (blast radius), 'out' = dependencies. Default 'both'."),
    depth: z.number().min(1).max(4).default(1).describe("Max hops. Default 1."),
  },
  async ({ node, direction, depth }) => {
    const slug = resolveActiveSlug();
    if (!slug) {
      return "code_neighbors: no active project resolvable (degenerate project dir) — no code graph to query.";
    }
    const result = await codeNeighbors({ brainDir: BRAIN_DIR, slug, node, direction, depth });
    if (result.kind === "missing") {
      return result.notice;
    }
    return result;
  }
);

// --- Start ---

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Knowledge MCP server running on stdio");
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
