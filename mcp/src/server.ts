import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "fs";
import os from "os";
import path from "path";
import { glob } from "glob";
import { pinToUser } from "./tools/pin-to-user.js";
import { pinToProject } from "./tools/pin-to-project.js";
import { archiveToWiki } from "./tools/archive-to-wiki.js";
import { knowledgeSearch } from "./tools/knowledge-search.js";
import { knowledgeFetch } from "./tools/knowledge-fetch.js";
import { knowledgeReindex } from "./tools/knowledge-reindex.js";
import { knowledgeValidate } from "./tools/knowledge-validate.js";
import { dreamCreate, dreamStatus, dreamList, dreamAccept, dreamDiscard, dreamCancel } from "./tools/dream.js";
import { episodicSearch, episodicRead, buildEpisodicIndex } from "./tools/episodic-search.js";
import { personaThink } from "./tools/persona-think.js";
import { personaStats } from "./tools/persona-stats.js";
import { personaDismiss } from "./tools/persona-dismiss.js";
import { capList, egressBudgetTokens } from "./tools/egress-budget.js";
import { knowledgeRelate } from "./tools/knowledge-relate.js";
import { knowledgeNeighbors } from "./tools/knowledge-neighbors.js";
import { slugFromProjectDir, activeProjectDir } from "./tools/project-dir.js";

function resolveKnowledgeDir(): string {
  const candidates = [
    process.env.KNOWLEDGE_DIR,
    process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR,
  ];
  for (const raw of candidates) {
    if (raw && raw.trim() && !raw.includes("${")) {
      return raw.startsWith("~") ? path.join(os.homedir(), raw.slice(1)) : raw;
    }
  }
  return path.join(os.homedir(), "knowledge");
}

const KNOWLEDGE_DIR = resolveKnowledgeDir();
const BRAIN_DIR = path.join(os.homedir(), '.second-brain');

function resolveActiveSlug(): string | undefined {
  // Mirror scripts/lib.sh sb_resolve_slug: prefer the pin (when its PROJECT.md exists), else basename(projectDir).
  try {
    const pin = fs.readFileSync(path.join(BRAIN_DIR, '.active-session-slug'), 'utf-8').trim();
    if (pin && fs.existsSync(path.join(BRAIN_DIR, 'projects', pin, 'PROJECT.md'))) return pin;
  } catch { /* no pin */ }
  // Prefer CLAUDE_PROJECT_DIR (Claude Code sets it in the stdio MCP server's env
  // to the project root — stable, unlike process.cwd() which is the MCP process's
  // launch dir and unreliable). Fall back to cwd on older CLIs that don't set it.
  return slugFromProjectDir(activeProjectDir());
}

const server = new McpServer(
  { name: "knowledge-base", version: "2.6.1" },
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

// --- Tools ---

server.registerTool(
  "knowledge_search",
  {
    description: "BM25-scored search across the knowledge base wiki. Reads full content of each markdown page, parses YAML frontmatter for field-weighted scoring (title 3x, description 2x, tags 2x, body 1x). Returns top 8 candidates with path, score, and snippet.",
    inputSchema: {
      query: z.string().describe("Search query — tokenized on lowercase alphanumerics, date tokens filtered out, matched via BM25 scoring."),
      scope: z.string().optional().describe("Restrict to a single wiki subdirectory (e.g. 'entities', 'learnings'). Omit to search all."),
    },
  },
  async ({ query, scope }) => {
    try {
      const result = await knowledgeSearch({ query, scope, knowledgeDir: KNOWLEDGE_DIR, brainDir: BRAIN_DIR, projectSlug: resolveActiveSlug() });
      return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
    } catch (error) {
      return {
        content: [{ type: "text" as const, text: `Search error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.registerTool(
  "knowledge_fetch",
  {
    description: "Fetch a wiki page at a chosen detail tier (progressive disclosure). tier: 'gist' (one-line), 'skeleton' (gist + headings), 'block' (the machine-first ai-block shared-intermediate — claim/action/etc — or the summary if none), 'summary' (the page's ## Summary section, or skeleton if none yet), 'full' (body, capped to the egress budget). Always returns a source pointer so you can escalate to the full page only when needed. Prefer this over reading the raw file for large pages.",
    inputSchema: {
      slug: z.string().describe("The page slug (filename without .md), e.g. from a knowledge_search result path."),
      tier: z.enum(["gist", "skeleton", "block", "summary", "full"]).optional().describe("Detail level. Default 'gist'."),
    },
  },
  async ({ slug, tier }) => {
    try {
      const result = await knowledgeFetch({ slug, tier, knowledgeDir: KNOWLEDGE_DIR });
      return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
    } catch (error) {
      return {
        content: [{ type: "text" as const, text: `Fetch error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.registerTool(
  "pin_to_user",
  {
    description: "Pin a preference to USER.md. Use only when the user explicitly says 'pin to my second-brain' or runs /second-brain:pin. Plain 'remember this' should write to Claude Code's built-in auto-memory, not here.",
    inputSchema: { text: z.string() },
  },
  async ({ text }) => {
    const result = await pinToUser({ text });
    return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
  }
);

server.registerTool(
  "pin_to_project",
  {
    description: "Append an entry to the active project's PROJECT.md. Section must be 'blockers' or 'decisions'.",
    inputSchema: {
      text: z.string(),
      slug: z.string(),
      section: z.enum(["blockers", "decisions"]),
    },
  },
  async ({ text, slug, section }) => {
    const result = await pinToProject({ text, slug, section });
    return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
  }
);

server.registerTool(
  "archive_to_wiki",
  {
    description: "Archive a [resolved] entry from PROJECT.md to ~/knowledge/wiki/<category>/<slug>/. Leaves a back-reference line in PROJECT.md.",
    inputSchema: {
      slug: z.string(),
      sourceSection: z.enum(["blockers", "decisions"]),
      entryText: z.string(),
      targetCategory: z.enum(["issues", "decisions"]),
    },
  },
  async (input) => {
    const result = await archiveToWiki(input);
    return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
  }
);

server.registerTool(
  "knowledge_stats",
  {
    description: "Get knowledge base statistics: total wiki files, files per category, and total bytes. Reads the wiki tree directly — no separate index to maintain.",
    inputSchema: z.object({}),
  },
  async () => {
    try {
      const wikiDir = path.join(KNOWLEDGE_DIR, "wiki");

      if (!fs.existsSync(wikiDir)) {
        return {
          content: [{
            type: "text" as const,
            text: [
              `# Knowledge Base Stats`,
              ``,
              `- **Knowledge dir**: ${KNOWLEDGE_DIR}`,
              `- **Wiki directory**: not present (run the setup skill to create it)`,
            ].join("\n"),
          }],
        };
      }

      const files = await glob("**/*.md", { cwd: wikiDir, absolute: true });
      const categories: Record<string, { count: number; bytes: number }> = {};
      let totalBytes = 0;

      for (const file of files) {
        const cat = categorizeFile(file);
        let size = 0;
        try {
          size = fs.statSync(file).size;
        } catch {
          // File vanished between glob and stat — skip silently.
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

      return {
        content: [{
          type: "text" as const,
          text: [
            `# Knowledge Base Stats`,
            ``,
            `- **Total wiki files**: ${files.length}`,
            `- **Total bytes**: ${totalBytes}`,
            `- **Knowledge dir**: ${KNOWLEDGE_DIR}`,
            ``,
            `## Categories`,
            catLines || "  (no pages yet)",
          ].join("\n"),
        }],
      };
    } catch (error) {
      return {
        content: [{ type: "text" as const, text: `Stats error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.registerTool(
  "knowledge_reindex",
  {
    description: "Regenerate wiki/index.md — a master catalog of all wiki pages with titles, descriptions, and category counts. Call after wiki writes or when index.md is stale.",
    inputSchema: z.object({}),
  },
  async () => {
    try {
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
      return {
        content: [{ type: "text" as const, text: lines.join('\n') }],
      };
    } catch (error) {
      return {
        content: [{ type: "text" as const, text: `Reindex error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.registerTool(
  "knowledge_validate",
  {
    description: "Validate knowledge base health: detect orphan files, broken wiki-links, missing frontmatter, duplicate slugs, empty pages, and root-level orphans. Auto-fixes safe issues (removes empty pages, empty root orphans). Returns all issues with severity and suggested fixes.",
    inputSchema: z.object({
      autofix: z.boolean().optional().describe("Auto-fix safe issues (empty pages, empty orphans). Default true."),
    }),
  },
  async ({ autofix }) => {
    try {
      const result = await knowledgeValidate(KNOWLEDGE_DIR, { autofix: autofix ?? true });
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
      return { content: [{ type: "text" as const, text: lines.join('\n') }] };
    } catch (error) {
      return {
        content: [{ type: "text" as const, text: `Validate error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

// --- Dream tools ---

server.registerTool(
  "dream_create",
  {
    description: "Start a new dream — async background consolidation of the knowledge base. Snapshots the wiki, selects session transcripts, and prepares for consolidation. Only one dream may be pending/running at a time.",
    inputSchema: {
      instructions: z.string().optional().describe("Guidance for the consolidation (max 4096 chars). E.g., 'Focus on React patterns; ignore one-off debugging notes.'"),
      transcript_filter: z.object({
        project_slug: z.string().optional().describe("Only include transcripts from this project"),
        since: z.string().optional().describe("Only include transcripts since this ISO date (YYYY-MM-DD)"),
        max_count: z.number().optional().describe("Max transcripts to include (default 50, max 100)"),
      }).optional(),
      model: z.string().optional().describe("Model for consolidation. Default: claude-sonnet-4-6"),
    },
  },
  async (args) => {
    const result = await dreamCreate(args);
    return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
  }
);

server.registerTool(
  "dream_status",
  {
    description: "Get the current status of a dream by ID. Returns lifecycle state, inputs, outputs, and a diff preview if completed.",
    inputSchema: {
      dream_id: z.string().describe("The dream ID (e.g., drm_20260511T143022Z)"),
    },
  },
  async (args) => {
    const result = await dreamStatus(args);
    return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
  }
);

server.registerTool(
  "dream_list",
  {
    description: "List all dreams, newest first. Excludes archived dreams by default.",
    inputSchema: {
      include_archived: z.boolean().optional().describe("Include archived dreams. Default false."),
    },
  },
  async (args) => {
    const result = await dreamList(args);
    return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
  }
);

server.registerTool(
  "dream_accept",
  {
    description: "Accept a completed dream — applies staged wiki changes to the live knowledge base. The dream is archived after acceptance.",
    inputSchema: {
      dream_id: z.string().describe("The dream ID to accept"),
    },
  },
  async (args) => {
    const result = await dreamAccept(args);
    return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
  }
);

server.registerTool(
  "dream_discard",
  {
    description: "Discard a dream's output without applying changes. Works on completed, failed, or canceled dreams.",
    inputSchema: {
      dream_id: z.string().describe("The dream ID to discard"),
    },
  },
  async (args) => {
    const result = await dreamDiscard(args);
    return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
  }
);

server.registerTool(
  "dream_cancel",
  {
    description: "Cancel a pending or running dream. Sets status to 'canceled' — does not terminate a running agent process (the agent checks status.json and stops on its own).",
    inputSchema: {
      dream_id: z.string().describe("The dream ID to cancel"),
    },
  },
  async (args) => {
    const result = await dreamCancel(args);
    return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
  }
);

// --- Episodic memory tools ---

server.registerTool(
  "episodic_search",
  {
    description: "Search past conversation transcripts using hybrid vector + text matching. Supports single query string or array of 2-5 concepts for AND matching. Returns ranked results with similarity scores, session metadata, and file paths for follow-up reading.",
    inputSchema: {
      query: z.union([
        z.string().describe("Search query for semantic + text matching"),
        z.array(z.string()).min(2).max(5).describe("2-5 concepts — returns only exchanges matching ALL"),
      ]),
      mode: z.enum(["vector", "text", "both"]).optional().describe("Search mode. Default: 'both'"),
      limit: z.number().min(1).max(30).optional().describe("Max results. Default: 10"),
      project: z.string().optional().describe("Filter by project slug (exact match)"),
      after: z.string().optional().describe("Only include results after this date (YYYY-MM-DD)"),
      before: z.string().optional().describe("Only include results before this date (YYYY-MM-DD)"),
    },
  },
  async (args) => {
    try {
      const result = await episodicSearch(args, BRAIN_DIR);
      if (result.results.length === 0) {
        return { content: [{ type: "text" as const, text: "No matching conversations found." }] };
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
      return { content: [{ type: "text" as const, text: capped.text }] };
    } catch (error) {
      return {
        content: [{ type: "text" as const, text: `Episodic search error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.registerTool(
  "episodic_read",
  {
    description: "Read full conversation context from a specific transcript file. Use after episodic_search to get complete exchange details.",
    inputSchema: {
      path: z.string().describe("Absolute path to the transcript file"),
      startLine: z.number().optional().describe("Start line (1-indexed). Omit to read from beginning."),
      endLine: z.number().optional().describe("End line (1-indexed). Omit to read to end."),
    },
  },
  async (args) => {
    try {
      const result = await episodicRead(args.path, args.startLine, args.endLine);
      const header = [
        `**Session**: ${result.sessionId}`,
        `**Project**: ${result.project}`,
        `**Date**: ${result.date}`,
        '---',
      ].join('\n');
      return { content: [{ type: "text" as const, text: `${header}\n${result.content}` }] };
    } catch (error) {
      return {
        content: [{ type: "text" as const, text: `Read error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.registerTool(
  "persona_think",
  {
    description: "Persona advisor brief. Spawn `claude -p` with Opus 4.7 (configurable via SB_PERSONA_MODEL) to produce a structured second opinion before answering a non-trivial prompt. Returns intent read, prompt enrichment, clarifying questions, relevant specialists, and risk flags. Use sparingly — Opus is expensive. Best for ambiguous prompts, design decisions, or multi-domain work where the persona's prior context matters.",
    inputSchema: {
      prompt: z.string().describe("The user prompt or topic to brief on."),
      context_hints: z.array(z.string()).optional().describe("Optional extra context strings to feed into the brief (e.g. relevant wiki snippets, project state)."),
    },
  },
  async (args) => {
    try {
      const result = await personaThink({ prompt: args.prompt, context_hints: args.context_hints }, { brainDir: BRAIN_DIR });
      return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
    } catch (error) {
      return {
        content: [{ type: "text" as const, text: `Persona think error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.registerTool(
  "persona_stats",
  {
    description: "Inspect the persona's current state — identity summary from persona-card.md, signal counts, installed catalog sizes, recent dismissals, today's persona spend vs daily budget. Read-only.",
    inputSchema: {},
  },
  async () => {
    try {
      const result = await personaStats({});
      return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
    } catch (error) {
      return {
        content: [{ type: "text" as const, text: `persona_stats error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.registerTool(
  "persona_dismiss",
  {
    description: "Record a dismissal: the persona's last suggestion was unhelpful. Feeds dismissal-aware backoff. Use when the user says the persona was wrong or noisy. Logged to ~/.second-brain/.persona-dismissals.jsonl.",
    inputSchema: {
      prompt_snippet: z.string().optional().describe("First ~200 chars of the prompt being dismissed."),
      reason: z.string().optional().describe("Why the suggestion was unhelpful."),
    },
  },
  async (args) => {
    try {
      const result = await personaDismiss(args);
      return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
    } catch (error) {
      return {
        content: [{ type: "text" as const, text: `persona_dismiss error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

// --- Relational graph tools ---

server.registerTool(
  "knowledge_relate",
  {
    description: "Assert (or invalidate) a typed, bi-temporal relationship between two wiki pages. Use when the user confirms that one thing relates to / requires / affects another, so a future session recalls it without re-explaining. types: requires | affects | relates | part_of | supersedes. Set invalidate:true with valid_to to mark a relationship no longer true (history is preserved, never deleted).",
    inputSchema: {
      from: z.string().describe("Source page slug (kebab-case)."),
      to: z.string().describe("Target page slug (kebab-case)."),
      type: z.enum(["requires", "affects", "relates", "part_of", "supersedes"]),
      valid_from: z.string().optional().describe("Date the relationship became true (YYYY-MM-DD). Default: today."),
      valid_to: z.string().optional().describe("Date it stopped being true (YYYY-MM-DD). Required semantics with invalidate:true."),
      invalidate: z.boolean().optional().describe("Mark an existing relationship no longer valid instead of asserting one."),
      reason: z.string().optional().describe("Why (especially on invalidate)."),
    },
  },
  async (args) => {
    try {
      const result = await knowledgeRelate({ ...args, knowledgeDir: KNOWLEDGE_DIR });
      return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
    } catch (error) {
      return { content: [{ type: "text" as const, text: `Relate error: ${error instanceof Error ? error.message : String(error)}` }], isError: true };
    }
  }
);

server.registerTool(
  "knowledge_neighbors",
  {
    description: "Walk the typed relationship graph from a page: multi-hop, time-filtered. direction 'out' = its dependencies (what it requires/affects), 'in' = its blast radius (what breaks if it changes), 'both' = default. Set as_of to a past date to reconstruct the graph as it was then. Returns edges with type, hops, score, and validity interval.",
    inputSchema: {
      slug: z.string().describe("The page slug to start from."),
      depth: z.number().min(1).max(4).optional().describe("Max hops. Default 2."),
      direction: z.enum(["out", "in", "both"]).optional().describe("Default 'both'."),
      edge_types: z.array(z.enum(["requires", "affects", "relates", "part_of", "supersedes"])).optional(),
      as_of: z.string().optional().describe("Point-in-time (YYYY-MM-DD or ISO). Default now."),
    },
  },
  async (args) => {
    try {
      const result = await knowledgeNeighbors({ ...args, knowledgeDir: KNOWLEDGE_DIR });
      return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
    } catch (error) {
      return { content: [{ type: "text" as const, text: `Neighbors error: ${error instanceof Error ? error.message : String(error)}` }], isError: true };
    }
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
