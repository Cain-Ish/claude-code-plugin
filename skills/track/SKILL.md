---
name: track
description: Declare which local folders or globs the second brain tracks as doc sources for the current project (e.g. docs/, .ai-docs/, "notes/**/*.mdx"). Tracked docs are auto-indexed each session and surface in knowledge_search. Usage: /second-brain:track <path|glob> | --list | --remove <path|glob>.
user-invocable: true
disable-model-invocation: false
allowed-tools: Bash(node *)
---

# /second-brain:track — declare local doc sources

Map the user's argument to a config-CLI action and run it. The CLI resolves the active project and atomically updates `~/.second-brain/projects/<slug>/doc-sources.config.json` (with dedup + validation).

Argument → action:
- `--list` (or no argument) → `list`
- `--remove <loc>` → `remove <loc>`
- `<loc>` — a folder like `docs/` or a glob like `notes/**/*.mdx` → `add <loc>`

Run exactly this (quote the location), then show the command's output to the user verbatim:

    node "${CLAUDE_PLUGIN_ROOT}/mcp/dist/tools/doc-sources-config-cli.bundle.js" <action> "<location>"

Then tell the user that newly-tracked locations are scanned into the searchable registry at the **next session start** (the `discover-doc-sources` SessionStart hook), after which `knowledge_search` will surface matching docs.
