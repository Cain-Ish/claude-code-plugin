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
import { knowledgeSearch, type Scope } from "./tools/knowledge-search.js";

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

const server = new McpServer(
  { name: "knowledge-base", version: "1.0.0" },
  {
    capabilities: { logging: {} },
    instructions: "Token-overlap search over the local knowledge base. Use knowledge_search to find relevant wiki pages, knowledge_stats for an overview of wiki size and categories, pin_to_user to record a user-level preference, pin_to_project to append blockers/decisions to a project's PROJECT.md, and archive_to_wiki to graduate a [resolved] entry from a project file into the wiki.",
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
    description: "Token-overlap search across the knowledge base wiki. Reads first lines of each markdown page under wiki/<scope>/ and ranks by overlap with query tokens. Returns top candidates with path, score, and a short snippet.",
    inputSchema: {
      query: z.string().describe("Search query — tokenized on lowercase alphanumerics and matched against page heads."),
      scope: z.enum(["concepts", "issues", "entities", "learnings", "decisions"]).optional().describe("Restrict to a single wiki subdirectory."),
    },
  },
  async ({ query, scope }) => {
    try {
      const result = await knowledgeSearch({
        query,
        scope: scope as Scope | undefined,
        knowledgeDir: KNOWLEDGE_DIR,
      });
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
