---
name: setup
description: Initialize the Second Brain knowledge base and learning state. Run once after installing the plugin, or anytime to verify the directory structure.
user-invocable: true
disable-model-invocation: true
allowed-tools: Bash(mkdir *) Bash(cat *) Bash(ls *) Bash(test *) Bash(bash *) Read
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

1. Run the ensure-dirs script to create all directories and seed files:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/ensure-dirs.sh
   ```

2. Verify the structure was created:
   ```bash
   ls -la ${user_config.knowledge_dir}/
   ls -la ${user_config.knowledge_dir}/wiki/
   ls -la ~/.second-brain/
   ```

3. Report what was created and confirm everything looks correct.

4. Mention to the user:
   - Use `/second-brain:ingest <path>` to add sources to the knowledge base
   - Use `/second-brain:query <question>` to search the knowledge base
   - The plugin automatically learns from sessions and improves code quality over time
   - **All data stays local** — nothing is ever synced, pushed, or shared externally
   - If using Obsidian: open `~/knowledge/` as a local-only vault — do NOT enable Obsidian Sync or any cloud sync plugins
   - Do NOT place the knowledge directory inside iCloud Drive, Dropbox, Google Drive, or OneDrive
