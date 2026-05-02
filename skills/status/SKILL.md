---
name: status
description: Show second-brain hot-tier and wiki health at a glance. Reports USER.md size, active PROJECT.md size, index.txt project count, and wiki page counts per category.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Bash(git rev-parse:*) Bash(basename *) Bash(wc *) Bash(cat *) Bash(ls *) Bash(test *) Bash(jq *) Bash(date *) Bash(find *) Bash(grep *) Bash(bash *) mcp__knowledge-base__knowledge_stats
---

<!-- user instruction verbatim: "1" -->

# Status

Show a compact dashboard of the v1.0 second-brain state: the hot tier (USER.md + active PROJECT.md + index.txt) plus the cold tier (wiki page counts per category).

## Steps

### 1. Resolve the active project

```bash
SLUG=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
echo "Active project: $SLUG"
```

### 2. Hot-tier sizes

Report byte counts for each hot-tier file. The combined target is ≤ ~3200 bytes (≈ 800 tokens).

```bash
USER_FILE=~/.second-brain/USER.md
PROJECT_FILE=~/.second-brain/projects/"$SLUG"/PROJECT.md
INDEX_FILE=~/.second-brain/index.txt

U=0; P=0
[ -f "$USER_FILE" ]    && U=$(wc -c < "$USER_FILE" | tr -d ' ')
[ -f "$PROJECT_FILE" ] && P=$(wc -c < "$PROJECT_FILE" | tr -d ' ')

echo "USER.md:    ${U} bytes"
echo "PROJECT.md ($SLUG): ${P} bytes"
echo "Combined:   $((U + P)) bytes (cap ≈ 3200)"
```

If the combined size exceeds ~3200 bytes, flag it — the hot tier is meant to stay small and always-loaded.

### 3. Index.txt project count

`index.txt` is JSONL; one record per registered project (see `setup` skill for the schema).

```bash
COUNT=0
[ -f "$INDEX_FILE" ] && COUNT=$(grep -c '"slug"' "$INDEX_FILE" 2>/dev/null || true)
echo "Registered projects: ${COUNT}"
```

If the active `$SLUG` is not in `index.txt`, surface that — the user probably should run `/second-brain:setup`.

### 4. Wiki page counts per category

Prefer the `knowledge_stats` MCP tool when available — it reads the wiki tree directly and returns a formatted breakdown:

```
knowledge_stats()
```

If the MCP tool is unavailable, fall back to a direct filesystem scan. Resolve the knowledge dir from the env var Claude Code injects per userConfig (skill-body `${user_config.X}` placeholders DO NOT expand in bash):

```bash
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
for dir in concepts issues entities learnings decisions; do
  N=$(find "$KD/wiki/$dir" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "  ${dir}: ${N}"
done
```

### 5. Pending PROJECT.md update flag

If the Stop-hook predicate fired in a recent session, a flag file is left for the next session to act on. Surface it so the user knows there is queued reflection work.

```bash
FLAG=~/.second-brain/.project-update-pending-"$SLUG"
if [ -f "$FLAG" ]; then
  echo "Pending PROJECT.md update flagged for $SLUG (run /second-brain:improve to apply)."
fi
```

### 6. Runtime smoke check

Run `verify.sh` to surface live-state issues that the static validator can't see (missing files, oversized hot tier, stale errors). Print its output verbatim — verify owns its own format.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify.sh"
```

The script exits 0 with `verify: ok` when everything is healthy, or exits non-zero with one `verify: FAIL:` line per failed check. Do not auto-remediate — point the user at the relevant skill (`/second-brain:setup` for missing files, `/second-brain:improve` for oversized hot tier) and let them act.

### 7. Present the dashboard

Format as a clean block. Example:

```
# Second-brain status

## Active project
- slug: claude-code-plugin

## Hot tier
- USER.md:    420 bytes
- PROJECT.md: 1180 bytes
- Combined:   1600 bytes (cap ~3200)
- Registered projects: 3

## Cold tier (wiki pages)
- concepts:  12
- issues:    4
- entities:  7
- learnings: 9
- decisions: 5

## Pending
- (none)
```

Keep the output terse. No reflection-pipeline metrics — `learnings.md`, `friction-log.jsonl`, `quality-rules.md`, `persona.md`, and `tool-registry.json` no longer exist. `error-log.jsonl` is not dumped here, but `verify.sh` (Step 6) flags new entries since the last successful verify. If the user wants deep reflection on the current session, point them at `/second-brain:improve`.
