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
import { knowledgeReindex } from "./tools/knowledge-reindex.js";
import { knowledgeValidate } from "./tools/knowledge-validate.js";
function resolveKnowledgeDir() {
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
const server = new McpServer({ name: "knowledge-base", version: "1.3.0" }, {
    capabilities: { logging: {} },
    instructions: "BM25-scored search over the local knowledge base. Use knowledge_search to find relevant wiki pages (searches full content with field-weighted scoring), knowledge_reindex to regenerate the wiki index.md catalog (also runs validation with autofix), knowledge_validate to check wiki health (broken links, orphans, duplicates, session-narrative pages), knowledge_stats for an overview of wiki size and categories, pin_to_user to record a user-level preference, pin_to_project to append blockers/decisions to a project's PROJECT.md, and archive_to_wiki to graduate a [resolved] entry from a project file into the wiki.",
});
function categorizeFile(filePath) {
    const rel = path.relative(path.join(KNOWLEDGE_DIR, "wiki"), filePath);
    const parts = rel.split(path.sep);
    return parts.length > 1 ? parts[0] : "uncategorized";
}
// --- Tools ---
server.registerTool("knowledge_search", {
    description: "BM25-scored search across the knowledge base wiki. Reads full content of each markdown page, parses YAML frontmatter for field-weighted scoring (title 3x, description 2x, tags 2x, body 1x). Returns top 8 candidates with path, score, and snippet.",
    inputSchema: {
        query: z.string().describe("Search query — tokenized on lowercase alphanumerics, date tokens filtered out, matched via BM25 scoring."),
        scope: z.string().optional().describe("Restrict to a single wiki subdirectory (e.g. 'entities', 'learnings'). Omit to search all."),
    },
}, async ({ query, scope }) => {
    try {
        const result = await knowledgeSearch({ query, scope, knowledgeDir: KNOWLEDGE_DIR });
        return { content: [{ type: "text", text: JSON.stringify(result) }] };
    }
    catch (error) {
        return {
            content: [{ type: "text", text: `Search error: ${error instanceof Error ? error.message : String(error)}` }],
            isError: true,
        };
    }
});
server.registerTool("pin_to_user", {
    description: "Pin a preference to USER.md. Use only when the user explicitly says 'pin to my second-brain' or runs /second-brain:pin. Plain 'remember this' should write to Claude Code's built-in auto-memory, not here.",
    inputSchema: { text: z.string() },
}, async ({ text }) => {
    const result = await pinToUser({ text });
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
});
server.registerTool("pin_to_project", {
    description: "Append an entry to the active project's PROJECT.md. Section must be 'blockers' or 'decisions'.",
    inputSchema: {
        text: z.string(),
        slug: z.string(),
        section: z.enum(["blockers", "decisions"]),
    },
}, async ({ text, slug, section }) => {
    const result = await pinToProject({ text, slug, section });
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
});
server.registerTool("archive_to_wiki", {
    description: "Archive a [resolved] entry from PROJECT.md to ~/knowledge/wiki/<category>/<slug>/. Leaves a back-reference line in PROJECT.md.",
    inputSchema: {
        slug: z.string(),
        sourceSection: z.enum(["blockers", "decisions"]),
        entryText: z.string(),
        targetCategory: z.enum(["issues", "decisions"]),
    },
}, async (input) => {
    const result = await archiveToWiki(input);
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
});
server.registerTool("knowledge_stats", {
    description: "Get knowledge base statistics: total wiki files, files per category, and total bytes. Reads the wiki tree directly — no separate index to maintain.",
    inputSchema: z.object({}),
}, async () => {
    try {
        const wikiDir = path.join(KNOWLEDGE_DIR, "wiki");
        if (!fs.existsSync(wikiDir)) {
            return {
                content: [{
                        type: "text",
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
        const categories = {};
        let totalBytes = 0;
        for (const file of files) {
            const cat = categorizeFile(file);
            let size = 0;
            try {
                size = fs.statSync(file).size;
            }
            catch {
                // File vanished between glob and stat — skip silently.
                continue;
            }
            totalBytes += size;
            if (!categories[cat])
                categories[cat] = { count: 0, bytes: 0 };
            categories[cat].count += 1;
            categories[cat].bytes += size;
        }
        const catLines = Object.entries(categories)
            .sort(([a], [b]) => a.localeCompare(b))
            .map(([cat, { count, bytes }]) => `  - ${cat}: ${count} pages, ${bytes} bytes`)
            .join("\n");
        return {
            content: [{
                    type: "text",
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
    }
    catch (error) {
        return {
            content: [{ type: "text", text: `Stats error: ${error instanceof Error ? error.message : String(error)}` }],
            isError: true,
        };
    }
});
server.registerTool("knowledge_reindex", {
    description: "Regenerate wiki/index.md — a master catalog of all wiki pages with titles, descriptions, and category counts. Call after wiki writes or when index.md is stale.",
    inputSchema: z.object({}),
}, async () => {
    try {
        const result = await knowledgeReindex(KNOWLEDGE_DIR);
        const lines = [`Reindexed ${result.pagesIndexed} pages across ${result.categories.length} categories.`];
        if (result.validation) {
            if (result.validation.fixed > 0)
                lines.push(`Auto-fixed ${result.validation.fixed} issues.`);
            const remaining = result.validation.issues.filter(i => !i.autofix || i.type !== 'empty_page');
            if (remaining.length > 0) {
                lines.push(`\nValidation issues (${remaining.length}):`);
                for (const issue of remaining.slice(0, 10)) {
                    lines.push(`  [${issue.severity}] ${issue.message}`);
                }
            }
        }
        return {
            content: [{ type: "text", text: lines.join('\n') }],
        };
    }
    catch (error) {
        return {
            content: [{ type: "text", text: `Reindex error: ${error instanceof Error ? error.message : String(error)}` }],
            isError: true,
        };
    }
});
server.registerTool("knowledge_validate", {
    description: "Validate knowledge base health: detect orphan files, broken wiki-links, missing frontmatter, duplicate slugs, empty pages, and root-level orphans. Auto-fixes safe issues (removes empty pages, empty root orphans). Returns all issues with severity and suggested fixes.",
    inputSchema: z.object({
        autofix: z.boolean().optional().describe("Auto-fix safe issues (empty pages, empty orphans). Default true."),
    }),
}, async ({ autofix }) => {
    try {
        const result = await knowledgeValidate(KNOWLEDGE_DIR, { autofix: autofix ?? true });
        const lines = [`Scanned ${result.pagesScanned} pages.`];
        if (result.fixed > 0)
            lines.push(`Auto-fixed ${result.fixed} issues.`);
        if (result.issues.length > 0) {
            lines.push(`\n${result.issues.length} issues found:`);
            for (const issue of result.issues) {
                lines.push(`  [${issue.severity}] ${issue.type}: ${issue.message}`);
            }
        }
        else {
            lines.push('No issues found.');
        }
        return { content: [{ type: "text", text: lines.join('\n') }] };
    }
    catch (error) {
        return {
            content: [{ type: "text", text: `Validate error: ${error instanceof Error ? error.message : String(error)}` }],
            isError: true,
        };
    }
});
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
//# sourceMappingURL=server.js.map