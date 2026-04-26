import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { embed } from "./embeddings.js";
import { VectorDB, type WikiPage } from "./vectordb.js";
import fs from "fs";
import os from "os";
import path from "path";
import { glob } from "glob";

function resolveKnowledgeDir(): string {
  const raw = process.env.KNOWLEDGE_DIR;
  // Skip unsubstituted placeholders like literal "${user_config.knowledge_dir}"
  if (raw && raw.trim() && !raw.includes("${")) {
    const expanded = raw.startsWith("~") ? path.join(os.homedir(), raw.slice(1)) : raw;
    return expanded;
  }
  return path.join(os.homedir(), "knowledge");
}

const KNOWLEDGE_DIR = resolveKnowledgeDir();

const server = new McpServer(
  { name: "knowledge-base", version: "0.1.0" },
  {
    capabilities: { logging: {} },
    instructions: "Semantic search over the local knowledge base. Use knowledge_search to find relevant wiki pages, knowledge_index to update embeddings after adding/modifying pages, and knowledge_stats for an overview.",
  }
);

let db: VectorDB | null = null;

function getDB(): VectorDB {
  if (!db) {
    db = new VectorDB(KNOWLEDGE_DIR);
  }
  return db;
}

function extractTitle(content: string): string {
  const match = content.match(/^#\s+(.+)$/m);
  return match ? match[1].trim() : "Untitled";
}

function categorizeFile(filePath: string): string {
  const rel = path.relative(path.join(KNOWLEDGE_DIR, "wiki"), filePath);
  const parts = rel.split(path.sep);
  return parts.length > 1 ? parts[0] : "uncategorized";
}

async function indexFile(vectordb: VectorDB, filePath: string): Promise<boolean> {
  let stat: fs.Stats;
  try {
    stat = fs.statSync(filePath);
  } catch {
    return false;
  }

  const lastModified = stat.mtimeMs;

  if (vectordb.isIndexed(filePath, lastModified)) {
    return false;
  }

  let content: string;
  try {
    content = fs.readFileSync(filePath, "utf-8");
  } catch {
    return false;
  }

  if (content.trim().length === 0) return false;

  const title = extractTitle(content);
  const category = categorizeFile(filePath);

  const embedding = await embed(`${title}\n\n${content}`);

  const page: WikiPage = {
    path: filePath,
    title,
    content,
    category,
    lastModified,
  };

  vectordb.upsertPage(page, embedding);
  return true;
}

// --- Tools ---

server.registerTool(
  "knowledge_search",
  {
    description: "Semantic search across the knowledge base wiki. Returns the most relevant pages ranked by similarity to the query. Use this to find information from past sessions, ingested sources, concepts, and entities.",
    inputSchema: z.object({
      query: z.string().describe("Natural language search query"),
      limit: z.number().optional().default(5).describe("Max results to return (default 5)"),
      category: z.string().optional().describe("Filter by category: sources, entities, concepts, synthesis, sessions"),
    }),
  },
  async ({ query, limit, category }) => {
    try {
      const vectordb = getDB();
      const queryEmbedding = await embed(query);
      const results = vectordb.search(queryEmbedding, limit, category);

      if (results.length === 0) {
        return {
          content: [{ type: "text", text: "No matching pages found in the knowledge base." }],
        };
      }

      const formatted = results.map((r, i) => {
        const relPath = path.relative(KNOWLEDGE_DIR, r.path);
        return `### ${i + 1}. ${r.title}\n**Path**: ${relPath}\n**Category**: ${r.category}\n**Relevance**: ${r.score.toFixed(3)}\n\n${r.excerpt}${r.excerpt.length >= 500 ? "..." : ""}`;
      }).join("\n\n---\n\n");

      return {
        content: [{ type: "text", text: formatted }],
      };
    } catch (error) {
      return {
        content: [{ type: "text", text: `Search error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.registerTool(
  "knowledge_index",
  {
    description: "Index or re-index wiki pages in the knowledge base. Generates embeddings for new or modified pages. Run this after adding or updating wiki pages via the ingest skill.",
    inputSchema: z.object({
      force: z.boolean().optional().default(false).describe("Force re-index all pages, even if unchanged"),
    }),
  },
  async ({ force }) => {
    try {
      const vectordb = getDB();
      const wikiDir = path.join(KNOWLEDGE_DIR, "wiki");

      if (!fs.existsSync(wikiDir)) {
        return {
          content: [{ type: "text", text: "Wiki directory not found. Run the setup skill first." }],
          isError: true,
        };
      }

      const files = await glob("**/*.md", { cwd: wikiDir, absolute: true });
      const existingPaths = new Set(files);

      let indexed = 0;
      let skipped = 0;

      for (const file of files) {
        if (force) {
          try {
            const content = fs.readFileSync(file, "utf-8");
            if (content.trim().length === 0) {
              skipped++;
              continue;
            }
            const title = extractTitle(content);
            const category = categorizeFile(file);
            const embedding = await embed(`${title}\n\n${content}`);
            vectordb.upsertPage(
              { path: file, title, content, category, lastModified: fs.statSync(file).mtimeMs },
              embedding
            );
            indexed++;
          } catch {
            skipped++;
          }
        } else {
          const wasIndexed = await indexFile(vectordb, file);
          if (wasIndexed) indexed++;
          else skipped++;
        }
      }

      // Persist the batch of upserts in one atomic write.
      vectordb.flush();
      const removed = vectordb.removeStale(existingPaths);

      return {
        content: [{
          type: "text",
          text: `Indexing complete.\n- Indexed: ${indexed} pages\n- Skipped (unchanged): ${skipped}\n- Removed (stale): ${removed}\n- Total wiki files: ${files.length}`,
        }],
      };
    } catch (error) {
      return {
        content: [{ type: "text", text: `Index error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.registerTool(
  "knowledge_stats",
  {
    description: "Get knowledge base statistics: total pages, pages per category, last indexed timestamp, and embedding coverage.",
    inputSchema: z.object({}),
  },
  async () => {
    try {
      const vectordb = getDB();
      const stats = vectordb.getStats();

      const wikiDir = path.join(KNOWLEDGE_DIR, "wiki");
      let totalFiles = 0;
      if (fs.existsSync(wikiDir)) {
        const files = await glob("**/*.md", { cwd: wikiDir });
        totalFiles = files.length;
      }

      const coverage = totalFiles > 0 ? ((stats.totalPages / totalFiles) * 100).toFixed(1) : "N/A";

      const catLines = Object.entries(stats.categories)
        .map(([cat, count]) => `  - ${cat}: ${count}`)
        .join("\n");

      return {
        content: [{
          type: "text",
          text: [
            `# Knowledge Base Stats`,
            ``,
            `- **Total indexed pages**: ${stats.totalPages}`,
            `- **Total wiki files**: ${totalFiles}`,
            `- **Embedding coverage**: ${coverage}%`,
            `- **Last indexed**: ${stats.lastIndexed || "never"}`,
            `- **Knowledge dir**: ${KNOWLEDGE_DIR}`,
            ``,
            `## Categories`,
            catLines || "  (no pages indexed yet)",
          ].join("\n"),
        }],
      };
    } catch (error) {
      return {
        content: [{ type: "text", text: `Stats error: ${error instanceof Error ? error.message : String(error)}` }],
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
