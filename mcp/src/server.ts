import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { embed } from "./embeddings.js";
import { VectorDB, type WikiPage } from "./vectordb.js";
import fs from "fs";
import os from "os";
import path from "path";
import { glob } from "glob";
import { execFileSync } from "child_process";
import { pinToUser } from "./tools/pin-to-user.js";
import { pinToProject } from "./tools/pin-to-project.js";
import { archiveToWiki } from "./tools/archive-to-wiki.js";

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
  { name: "knowledge-base", version: "0.2.0" },
  {
    capabilities: { logging: {} },
    instructions: "Semantic search over the local knowledge base. Use knowledge_search to find relevant wiki pages, knowledge_index to update embeddings after adding/modifying pages, knowledge_stats for an overview, and knowledge_feedback to report whether retrieved knowledge was helpful.",
  }
);

let db: VectorDB | null = null;

async function getDB(): Promise<VectorDB> {
  if (!db) {
    const instance = new VectorDB(KNOWLEDGE_DIR);
    await instance.ready();
    db = instance;
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

async function indexFile(vectordb: VectorDB, filePath: string, force = false): Promise<boolean> {
  let stat: fs.Stats;
  try {
    stat = fs.statSync(filePath);
  } catch {
    return false;
  }

  const lastModified = stat.mtimeMs;

  if (!force && vectordb.isIndexed(filePath, lastModified)) {
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

// Auto-reindex: check for changed files before each search (30s cooldown)
let lastAutoIndexCheck = 0;
const AUTO_INDEX_COOLDOWN = 30_000;

async function maybeAutoIndex(vectordb: VectorDB): Promise<void> {
  const now = Date.now();
  if (now - lastAutoIndexCheck < AUTO_INDEX_COOLDOWN) return;

  lastAutoIndexCheck = now;

  const wikiDir = path.join(KNOWLEDGE_DIR, "wiki");
  if (!fs.existsSync(wikiDir)) return;

  const files = await glob("**/*.md", { cwd: wikiDir, absolute: true });
  let reindexed = 0;
  const deadline = Date.now() + 5000;

  for (const file of files) {
    if (Date.now() > deadline) break;
    try {
      const wasIndexed = await indexFile(vectordb, file);
      if (wasIndexed) reindexed++;
    } catch (err) {
      console.error(`Auto-reindex failed for ${file}: ${err instanceof Error ? err.message : err}`);
    }
  }

  const existingPaths = new Set(files);
  const removed = vectordb.removeStale(existingPaths);
  if (reindexed > 0 || removed > 0) {
    vectordb.flush();
    console.error(`Auto-reindex: ${reindexed} updated, ${removed} stale removed`);
  }
}

// --- Tools ---

server.registerTool(
  "knowledge_search",
  {
    description: "Hybrid semantic + keyword search across the knowledge base wiki. Returns pages ranked by combined vector similarity and BM25 keyword relevance. Accepts a single query string or an array of 2-5 concept strings for AND intersection.",
    inputSchema: z.object({
      query: z.union([
        z.string(),
        z.array(z.string()).min(2).max(5),
      ]).describe("Natural language search query, or array of 2-5 concept strings for AND intersection"),
      limit: z.number().optional().default(5).describe("Max results to return (default 5)"),
      category: z.string().optional().describe("Filter by category: sources, entities, concepts, synthesis, sessions, learnings, patterns, issues, decisions"),
      full: z.boolean().optional().default(false).describe("Return full page content instead of excerpts (use for deep reads)"),
    }),
  },
  async ({ query, limit, category, full }) => {
    try {
      const vectordb = await getDB();
      await maybeAutoIndex(vectordb);

      let results;
      let partialFallback = false;
      if (typeof query === "string") {
        const queryEmbedding = await embed(query);
        results = vectordb.search(queryEmbedding, limit, category, 0.25, query);
      } else {
        const multi = await multiConceptSearch(vectordb, query, limit, category);
        results = multi.results;
        partialFallback = multi.partial;
      }

      if (results.length > 0) {
        vectordb.recordAccess(results.map(r => r.path));
      }

      if (results.length === 0) {
        return {
          content: [{ type: "text" as const, text: "No matching pages found in the knowledge base." }],
        };
      }

      const formatted = results.map((r, i) => {
        const relPath = path.relative(KNOWLEDGE_DIR, r.path);
        if (full) {
          let body = r.excerpt;
          try { body = fs.readFileSync(r.path, "utf-8"); } catch { /* fall back to excerpt */ }
          return `### ${i + 1}. ${r.title}\n**Path**: ${relPath}\n**Category**: ${r.category}\n**Relevance**: ${r.score.toFixed(3)}\n\n${body}`;
        }
        const preview = r.excerpt.slice(0, 200);
        return `${i + 1}. **${r.title}** (${r.category}, ${r.score.toFixed(2)}) — ${relPath}\n   ${preview}${preview.length >= 200 ? "..." : ""}`;
      }).join(full ? "\n\n---\n\n" : "\n");

      const prefix = partialFallback
        ? "(No exact intersection found across all concepts; showing results for first concept only)\n\n"
        : "";
      return {
        content: [{ type: "text" as const, text: prefix + formatted }],
      };
    } catch (error) {
      return {
        content: [{ type: "text" as const, text: `Search error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

async function multiConceptSearch(
  vectordb: VectorDB,
  concepts: string[],
  limit: number,
  category?: string,
): Promise<{ results: import("./vectordb.js").SearchResult[]; partial: boolean }> {
  const widerLimit = limit * 3;
  const lowerMinScore = 0.2;

  const resultSets = await Promise.all(
    concepts.map(async (concept) => {
      const embedding = await embed(concept);
      return vectordb.search(embedding, widerLimit, category, lowerMinScore, concept);
    })
  );

  const scoreMaps = resultSets.map(
    (results) => new Map(results.map((r) => [r.path, r]))
  );

  const firstSet = scoreMaps[0];
  const intersected: Array<{ path: string; avgScore: number; result: import("./vectordb.js").SearchResult }> = [];

  for (const [p, result] of firstSet) {
    const scores = [result.score];
    let inAll = true;
    for (let i = 1; i < scoreMaps.length; i++) {
      const match = scoreMaps[i].get(p);
      if (!match) {
        inAll = false;
        break;
      }
      scores.push(match.score);
    }
    if (inAll) {
      intersected.push({
        path: p,
        avgScore: scores.reduce((a, b) => a + b, 0) / scores.length,
        result,
      });
    }
  }

  if (intersected.length > 0) {
    intersected.sort((a, b) => b.avgScore - a.avgScore);
    return {
      results: intersected.slice(0, limit).map((i) => ({
        ...i.result,
        score: i.avgScore,
      })),
      partial: false,
    };
  }

  console.error(`Multi-concept search: no intersection for [${concepts.join(", ")}], falling back to first concept`);
  return { results: resultSets[0].slice(0, limit), partial: true };
}

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
  "knowledge_index",
  {
    description: "Index or re-index wiki pages in the knowledge base. Generates embeddings for new or modified pages. Run this after adding or updating wiki pages via the ingest skill.",
    inputSchema: z.object({
      force: z.boolean().optional().default(false).describe("Force re-index all pages, even if unchanged"),
    }),
  },
  async ({ force }) => {
    try {
      const vectordb = await getDB();
      const wikiDir = path.join(KNOWLEDGE_DIR, "wiki");

      if (!fs.existsSync(wikiDir)) {
        return {
          content: [{ type: "text" as const, text: "Wiki directory not found. Run the setup skill first." }],
          isError: true,
        };
      }

      const files = await glob("**/*.md", { cwd: wikiDir, absolute: true });
      const existingPaths = new Set(files);

      let indexed = 0;
      let skipped = 0;

      for (const file of files) {
        try {
          const wasIndexed = await indexFile(vectordb, file, force);
          if (wasIndexed) indexed++;
          else skipped++;
        } catch (err) {
          console.error(`Index failed for ${file}: ${err instanceof Error ? err.message : err}`);
          skipped++;
        }
      }

      const removed = vectordb.removeStale(existingPaths);
      vectordb.flush();

      return {
        content: [{
          type: "text" as const,
          text: `Indexing complete.\n- Indexed: ${indexed} pages\n- Skipped (unchanged): ${skipped}\n- Removed (stale): ${removed}\n- Total wiki files: ${files.length}`,
        }],
      };
    } catch (error) {
      return {
        content: [{ type: "text" as const, text: `Index error: ${error instanceof Error ? error.message : String(error)}` }],
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
      const vectordb = await getDB();
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
          type: "text" as const,
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
        content: [{ type: "text" as const, text: `Stats error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

server.registerTool(
  "knowledge_feedback",
  {
    description: "Provide feedback on retrieved knowledge. For wiki pages, updates access priority. For learnings, adjusts confidence and hit count.",
    inputSchema: z.object({
      path: z.string().describe("File path of the wiki page or learning entry"),
      helpful: z.boolean().describe("Whether the retrieved knowledge was helpful"),
      context: z.string().optional().describe("Brief note on how it was used"),
      entry: z.string().optional().describe("For learnings.md: unique substring from the entry header (e.g. '2026-04-27] Tests must exercise' or 'Validate plugin config'). Must match exactly one ## [...] header."),
    }),
  },
  async ({ path: filePath, helpful, context, entry }) => {
    try {
      const rawResolved = path.resolve(
        filePath.startsWith("~") ? path.join(os.homedir(), filePath.slice(1)) : filePath
      );
      let resolved: string;
      try {
        resolved = fs.realpathSync(rawResolved);
      } catch {
        resolved = rawResolved;
      }
      let knowledgeResolved: string, brainResolved: string;
      try { knowledgeResolved = fs.realpathSync(path.resolve(KNOWLEDGE_DIR)); } catch { knowledgeResolved = path.resolve(KNOWLEDGE_DIR); }
      try { brainResolved = fs.realpathSync(path.resolve(path.join(os.homedir(), ".second-brain"))); } catch { brainResolved = path.resolve(path.join(os.homedir(), ".second-brain")); }
      if (!resolved.startsWith(knowledgeResolved + path.sep) && !resolved.startsWith(brainResolved + path.sep)
          && resolved !== knowledgeResolved && resolved !== brainResolved) {
        return {
          content: [{ type: "text" as const, text: "Path must be within knowledge or second-brain directory" }],
          isError: true,
        };
      }

      if (resolved.endsWith("learnings.md")) {
        return updateLearningFeedback(resolved, helpful, context, entry);
      }

      const vectordb = await getDB();
      const delta = helpful ? 1 : -1;
      const updated = vectordb.updateAccessCount(resolved, delta);

      if (!updated) {
        return {
          content: [{ type: "text" as const, text: `Page not found in index: ${resolved}` }],
          isError: true,
        };
      }

      return {
        content: [{ type: "text" as const, text: `Feedback recorded for ${path.basename(resolved)}: ${helpful ? "helpful (+1)" : "not helpful (-1)"}${context ? ` — ${context}` : ""}` }],
      };
    } catch (error) {
      return {
        content: [{ type: "text" as const, text: `Feedback error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);

function updateLearningFeedback(
  resolvedPath: string,
  helpful: boolean,
  context?: string,
  entry?: string,
): { content: Array<{ type: "text"; text: string }>; isError?: boolean } {
  if (!fs.existsSync(resolvedPath)) {
    return {
      content: [{ type: "text", text: `File not found: ${resolvedPath}` }],
      isError: true,
    };
  }

  let content = fs.readFileSync(resolvedPath, "utf-8");
  const today = new Date().toISOString().slice(0, 10);

  const metaRegex = /<!-- meta: confidence=([0-9]+(?:\.[0-9]+)?) hits=(\d+) last_used=(\d{4}-\d{2}-\d{2}) -->/g;

  if (entry) {
    const headerRegex = /^## \[.+$/gm;
    const matches: Array<{ index: number; line: string }> = [];
    let headerMatch: RegExpExecArray | null;
    while ((headerMatch = headerRegex.exec(content)) !== null) {
      if (headerMatch[0].includes(entry)) {
        matches.push({ index: headerMatch.index, line: headerMatch[0] });
      }
    }

    if (matches.length === 0) {
      return {
        content: [{ type: "text", text: `No learning entry matching '${entry}' in ${resolvedPath}` }],
        isError: true,
      };
    }
    if (matches.length > 1) {
      const titles = matches.map(m => m.line).join("\n");
      return {
        content: [{ type: "text", text: `Ambiguous: '${entry}' matches ${matches.length} entries. Provide a more specific substring:\n${titles}` }],
        isError: true,
      };
    }

    metaRegex.lastIndex = matches[0].index;
    const match = metaRegex.exec(content);
    if (!match) {
      return {
        content: [{ type: "text", text: `No meta line found for entry '${entry}'.` }],
        isError: true,
      };
    }

    let confidence = parseFloat(match[1]);
    let hits = parseInt(match[2], 10);
    if (helpful) { confidence = Math.min(1.0, confidence + 0.05); hits += 1; }
    else { confidence = Math.max(0.0, confidence - 0.05); }

    const newMeta = `<!-- meta: confidence=${confidence.toFixed(2)} hits=${hits} last_used=${today} -->`;
    content = content.slice(0, match.index) + newMeta + content.slice(match.index + match[0].length);

    atomicWrite(resolvedPath, content);
    return {
      content: [{ type: "text", text: `Learning [${matches[0].line.slice(3)}] updated: confidence=${confidence.toFixed(2)}, hits=${hits}${context ? ` — ${context}` : ""}` }],
    };
  }

  // Fallback: no entry specified — update first meta line (legacy behavior)
  const match = metaRegex.exec(content);
  if (!match) {
    return {
      content: [{ type: "text", text: "No meta line found in learnings file to update." }],
      isError: true,
    };
  }

  let confidence = parseFloat(match[1]);
  let hits = parseInt(match[2], 10);
  if (helpful) { confidence = Math.min(1.0, confidence + 0.05); hits += 1; }
  else { confidence = Math.max(0.0, confidence - 0.05); }

  const newMeta = `<!-- meta: confidence=${confidence.toFixed(2)} hits=${hits} last_used=${today} -->`;
  content = content.slice(0, match.index) + newMeta + content.slice(match.index + match[0].length);

  atomicWrite(resolvedPath, content);
  return {
    content: [{ type: "text", text: `Learning updated: confidence=${confidence.toFixed(2)}, hits=${hits}${context ? ` — ${context}` : ""}` }],
  };
}

function atomicWrite(filePath: string, data: string): void {
  const lockPath = path.join(path.dirname(filePath), ".learnings.lock");
  const tmpPath = filePath + ".tmp";
  fs.writeFileSync(tmpPath, data, "utf-8");
  try {
    // flock coordinates with decay-learnings.sh which uses the same lockfile
    execFileSync("flock", ["-w", "5", lockPath, "mv", tmpPath, filePath], { timeout: 10000 });
  } catch {
    // Fallback if flock unavailable (e.g. Windows): direct rename
    try { fs.renameSync(tmpPath, filePath); } catch (err) {
      try { fs.unlinkSync(tmpPath); } catch { /* best-effort */ }
      throw err;
    }
  }
}

// --- Start ---

function flushOnExit(signal: string): void {
  try {
    if (db) db.close();
  } catch (err) {
    console.error(`Flush failed during ${signal}:`, err);
  }
}

async function main() {
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
    process.on(sig, () => {
      flushOnExit(sig);
      process.exit(0);
    });
  }
  process.on("beforeExit", () => flushOnExit("beforeExit"));

  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Knowledge MCP server running on stdio");
}

main().catch((error) => {
  console.error("Fatal error:", error);
  flushOnExit("fatal");
  process.exit(1);
});
