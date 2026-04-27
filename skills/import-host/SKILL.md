---
name: import-host
description: Detect existing AI-context files on the host (CLAUDE.md, AGENTS.md, .cursorrules, .windsurfrules, .continuerules) in $HOME and the current repo, and offer to import them as wiki sources or merge into persona/quality-rules. Critic-gated. Use after a fresh /second-brain:setup to pull in everything you've already written.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Write Edit Agent Bash(test *) Bash(ls *) Bash(cat *) Bash(wc *) Bash(date *) Bash(grep *) Bash(find *) Bash(jq *) Bash(git *)
---

# Host Context Import

Bootstrap the wiki and learning state from existing AI-context files you've already written. Pulls from common conventions across Claude Code, Aider, Cursor, Continue, Windsurf, and AGENTS.md (the OpenCode/agent-rules standard).

## Steps

### 1. Detect candidates

Walk known locations and report what exists. Search at two scopes: home (`$HOME`) and the current repo root (the directory containing `.git`, walking up from cwd).

```bash
declare -a CANDIDATES=(
  "$HOME/CLAUDE.md"
  "$HOME/AGENTS.md"
  "$HOME/.cursorrules"
  "$HOME/.claude/CLAUDE.md"
  "$HOME/.claude/instructions.md"
)

# Also walk up from cwd to find a .git root, and check for repo-local files.
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$GIT_ROOT" ]; then
  for f in CLAUDE.md AGENTS.md .cursorrules .windsurfrules .continuerules instructions.md; do
    [ -f "$GIT_ROOT/$f" ] && CANDIDATES+=("$GIT_ROOT/$f")
  done
fi

for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ]; then
    LINES=$(wc -l < "$c" | tr -d ' ')
    printf '  %s (%s lines)\n' "$c" "$LINES"
  fi
done
```

### 2. Categorize by intent

For each detected file, read the first 50 lines and decide: is this primarily about **persona/style** (rules for how the AI should behave) or **project/architecture** (facts about the codebase)?

Heuristics:
- Words like "tone", "style", "voice", "anti-pattern", "always/never do X" -> persona-bound
- Words like "architecture", "stack", "deployment", "the codebase uses" -> project-bound
- Mixed -> recommend splitting

Report your categorization to the user before doing anything.

### 3. For each accepted candidate — import path

The user picks one of three import paths per file:

**(a) Wiki source** (default, safest): write to `~/knowledge/wiki/sources/imported-<host>-<slug>.md` using the standard ingest schema with `Coverage: medium`, `Freshness tier: 90d`. The original file stays untouched. Future `/second-brain:query` can find it.

**(b) Persona merge** (critic-gated): for files clearly about behavioral rules. Run the same adversarial critic gate as `/second-brain:improve` step 5.5 — fresh-context subagent reviews each proposed merge against current `persona.md` for conflicts. Only ACCEPTED rules are appended. Append `## History` line to persona.md citing the source.

**(c) Quality-rules merge** (critic-gated): for files about code conventions. Same critic gate.

### 4. Skip duplicates

Before importing, grep `~/knowledge/wiki/sources/` for any existing `imported-*` file referencing the same source path. If found, ask: "Re-import (overwrite) or skip?"

### 5. Write the import log

Append to `~/.second-brain/import-log.jsonl`:

```bash
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -nc \
  --arg t "$NOW" --arg src "$SOURCE_PATH" --arg dst "$DEST_PATH" --arg path "$IMPORT_PATH" \
  '{timestamp:$t, source:$src, destination:$dst, import_path:$path}' \
  >> ~/.second-brain/import-log.jsonl
```

### 6. Update wiki/log.md and index.md

For each new wiki source page, append the standard ingest log entry and add the page to `~/knowledge/index.md` under the right category.

### 7. Suggest next step

After import, suggest the user run `/second-brain:lint` to catch overlap with anything that was already in the wiki, and `/second-brain:graph rebuild` if many new pages were imported.

## Notes

- This is a **bootstrap** skill — most useful right after `/second-brain:setup`. Subsequent imports of the same host file are duplicate-detected.
- Never delete or modify the source files — `~/CLAUDE.md` and friends stay where they are.
- Critic gate is non-negotiable for persona/quality-rules merges. Importing a stale rule that contradicts current persona is exactly the kind of regression the critic catches.
- Repo-local imports respect the current repo's git root only. Importing from arbitrary paths is supported by `/second-brain:ingest <path>` instead.
