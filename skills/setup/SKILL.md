---
name: setup
description: Initialize the Second Brain knowledge base, learning state, and MCP server build. Run once after installing the plugin, or anytime to verify the directory structure.
user-invocable: true
disable-model-invocation: true
allowed-tools: Bash(mkdir *) Bash(cat *) Bash(ls *) Bash(test *) Bash(bash *) Bash(npm install:*) Bash(npm run:*) Read
---

# Second Brain Setup

Initialize the local knowledge base and learning state directories.

## What This Creates

### Knowledge Base (`${user_config.knowledge_dir}` — default `~/knowledge/`)

The Karpathy-inspired wiki structure:

```
~/knowledge/
├── raw/              # Immutable source documents (articles, papers, notes)
│   └── assets/       # Images, PDFs, attachments
├── wiki/             # LLM-maintained pages (you manage this automatically)
│   ├── sources/      # Summaries of ingested raw sources
│   ├── entities/     # People, organizations, products, tools
│   ├── concepts/     # Ideas, frameworks, patterns, theories
│   ├── synthesis/    # Cross-cutting analyses connecting multiple topics
│   └── sessions/     # Insights extracted from coding sessions
├── .embeddings/      # Vector store for semantic search (MCP server)
├── index.md          # Content catalog — updated on each ingest
├── log.md            # Chronological record of all operations
└── schema.md         # Wiki conventions and structure rules
```

### Learning State (`~/.second-brain/`)


```
~/.second-brain/
├── learnings.md       # Accumulated strategic principles from sessions
├── quality-rules.md   # Auto-evolved code quality standards
├── tool-registry.json # Discovered MCP tools (auto-updated each session)
└── friction-log.jsonl # Detected user correction/retry signals
```

## Steps

1. Run the ensure-dirs script to create all directories and seed files. The script's internal fallback chain (`$1` → `$CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR` → `~/knowledge`) honors the user's configured location via the auto-injected env var, so we don't need to substitute `${user_config.knowledge_dir}` in the skill body (that placeholder doesn't expand in skill bash blocks):
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/ensure-dirs.sh
   ```

2. Verify the structure was created:
   ```bash
   KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
   ls -la "$KD/"
   ls -la "$KD/wiki/"
   ls -la ~/.second-brain/
   ```

3. The MCP server ships pre-built (`mcp/dist/server.js` is tracked in git), so most installs do nothing here. Only rebuild if the file is missing — typically only happens if you cloned with sparse-checkout or deleted `dist/`:
   ```bash
   if [ ! -f "${CLAUDE_PLUGIN_ROOT}/mcp/dist/server.js" ]; then
     (cd "${CLAUDE_PLUGIN_ROOT}/mcp" && npm install --no-fund --no-audit && npm run build) || \
       echo "MCP build failed — knowledge_search/index/stats will not work until you run: cd ${CLAUDE_PLUGIN_ROOT}/mcp && npm install && npm run build"
   fi
   ```
   Report whether the build ran, was skipped (already shipped), or failed.

4. Report what was created and confirm everything looks correct.

5. Mention to the user:
   - Use `/second-brain:ingest <path>` to add sources to the knowledge base
   - Use `/second-brain:query <question>` to search the knowledge base
   - The plugin automatically learns from sessions and improves code quality over time
   - **All data stays local** — nothing is ever synced, pushed, or shared externally
   - If using Obsidian: open `~/knowledge/` as a local-only vault — do NOT enable Obsidian Sync or any cloud sync plugins
   - Do NOT place the knowledge directory inside iCloud Drive, Dropbox, Google Drive, or OneDrive
