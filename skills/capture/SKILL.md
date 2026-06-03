---
name: capture
description: Drop unprocessed material (a file, a URL, or pasted text) into the current project's raw inbox for later refinement into wiki notes. Usage: /second-brain:capture <path|url> | "<text>" | --list | --discard <id> | --node <slug>.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Bash(node *) Bash(test *) Bash(cat *) Bash(basename *)
---

# /second-brain:capture — raw inbox producer

Hold unprocessed material in the active project's raw inbox
(`~/.second-brain/projects/<slug>/raw/`) until the maintainer refines it into wiki
nodes. Raw items are **not** searched — they are a staging area, surfaced as a
backlog count at session start.

Map the user's argument to a `raw-capture-cli` action and run it. The CLI resolves
the active project, stamps provenance, copies blobs, and dedups by content hash.

```bash
CLI="${CLAUDE_PLUGIN_ROOT}/mcp/dist/tools/raw-capture-cli.bundle.js"
```

- `<path>` or `<url>` or inline `"text"` → `node "$CLI" capture <arg> [--node <slug>]`
- pasted/piped text → `node "$CLI" paste [--node <slug>]` (reads stdin)
- `--list` → `node "$CLI" list`
- `--discard <id>` → `node "$CLI" discard <id>`

`--node <slug>` records that the item is evidence for an existing wiki page
(provenance only — the link is projected later when the maintainer processes it).

Relay the CLI's output. If it reports "could not resolve the active project", tell
the user to `cd` into their project directory first.
