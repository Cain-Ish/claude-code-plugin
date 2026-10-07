---
name: capture
description: Reference only, never invoked — documents raw-capture-cli, the bundled CLI that files a file, URL or pasted text into the current project's raw inbox for /second-brain:maintain to refine into wiki notes. Run it directly with node (capture, paste, list, discard, prune-processed).
# Surface-collapse (0.29.0): not a user slash command, and disable-model-invocation means NOTHING
# can invoke this skill (no user, no model, no hook). It only documents the bundled raw-capture-cli
# for direct or scripted use. What actually feeds the raw inbox (checked against the code, R3
# 2026-10-07): /second-brain:setup's one-time deep-scan (raw-scan-cli, after a confirm) and anyone
# running raw-capture-cli by hand or from a script. No hook, MCP tool or drainer writes raw items.
# Only /second-brain:maintain (its raw-drainer agent, in a Claude session) drains them.
user-invocable: false
disable-model-invocation: true
allowed-tools: Read Bash(node *) Bash(test *) Bash(cat *) Bash(basename *)
---

# raw-capture-cli — the raw inbox producer (reference)

This skill cannot be invoked: its frontmatter disables both user and model invocation. It
documents the bundled CLI that holds unprocessed material in the active project's raw inbox
(`~/.second-brain/projects/<slug>/raw/`) until `/second-brain:maintain` refines it into wiki
nodes. Raw items are **not** searched: they are a staging area, surfaced as a backlog count at
session start.

## What feeds the raw inbox

- `/second-brain:setup` step 6: a one-time deep-scan of the repo's docs (`raw-scan-cli`, a
  `--dry-run` preview, then your confirm).
- `raw-capture-cli`, run by you or by your own script (below).

Nothing else writes raw items: no hook, MCP tool or drainer timer. Nothing drains them on its own
either: only `/second-brain:maintain` (its `raw-drainer` agent) does, inside a Claude session.

## Running the CLI

The CLI resolves the active project from the current directory, stamps provenance, copies blobs
and dedups by content hash.

```bash
CLI="${CLAUDE_PLUGIN_ROOT}/mcp/dist/tools/raw-capture-cli.bundle.js"
```

- a `<path>`, `<url>` or inline `"text"`: `node "$CLI" capture <arg> [--node <slug>]`
- piped text: `node "$CLI" paste [--node <slug>]` (reads stdin)
- list the inbox: `node "$CLI" list`
- drop one item: `node "$CLI" discard <id>`
- `node "$CLI" prune-processed`: delete this project's **processed + discarded** audit-trail items
  (unprocessed and malformed are kept). Opt-in cleanup, **off by default**: processed raw `.md`
  files are normally kept as provenance and as the drain's truncation-recovery trail, and are
  **never searched** (search is scoped to `~/knowledge/wiki/`), so keeping them costs no
  retrieval. To prune automatically after each drain batch, set `SB_RAW_PRUNE_AFTER_DRAIN=1`.

`--node <slug>` records that the item is evidence for an existing wiki page (provenance only;
the link is projected when the maintainer processes it).

If the CLI reports "could not resolve the active project", `cd` into the project directory first.
