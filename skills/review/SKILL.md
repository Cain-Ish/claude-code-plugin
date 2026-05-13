---
name: review
description: Surface open blockers, stale projects, pending dreams, and ungraduated persona signals across all registered projects. Read-only daily/weekly overview.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Bash(jq *) Bash(date *) Bash(find *) Bash(ls *) Bash(test *) Bash(cat *) Bash(wc *) Bash(grep *) Bash(sed *) Bash(awk *) mcp__knowledge-base__knowledge_stats
---

# Review

A cross-project overview: what's blocked, what's stale, what's queued. Read-only — no mutations. Run when you start a new day or wrap a context switch.

## Steps

### 1. Open blockers across all projects

Read every `~/.second-brain/projects/*/PROJECT.md`. For each, extract lines under `## Open blockers`. Show them grouped by project slug. Skip projects with empty blocker sections.

```bash
for pf in ~/.second-brain/projects/*/PROJECT.md; do
  [ -f "$pf" ] || continue
  slug=$(basename "$(dirname "$pf")")
  blockers=$(awk '/^## Open blockers/{flag=1;next}/^## /{flag=0}flag' "$pf" | grep -E '^- ' || true)
  if [ -n "$blockers" ]; then
    echo "## $slug"
    echo "$blockers"
    echo
  fi
done
```

### 2. Stale projects

A project is stale if its last extraction (from `~/.second-brain/.last-extracted-line-<slug>`) or PROJECT.md mtime is older than 14 days. Surface them so the user knows what's drifted.

```bash
THRESHOLD=$(date -u -d '14 days ago' +%s 2>/dev/null || date -u -v -14d +%s 2>/dev/null)
for pf in ~/.second-brain/projects/*/PROJECT.md; do
  [ -f "$pf" ] || continue
  slug=$(basename "$(dirname "$pf")")
  mtime=$(date -r "$pf" +%s 2>/dev/null)
  if [ -n "$mtime" ] && [ -n "$THRESHOLD" ] && [ "$mtime" -lt "$THRESHOLD" ]; then
    days=$(( ( $(date -u +%s) - mtime ) / 86400 ))
    echo "  $slug — last touched ${days}d ago"
  fi
done
```

### 3. Pending dreams

If `~/.second-brain/dreams/` has any `drm_*/status.json` files in `completed` state without `archived_at` set, flag them for review with `/second-brain:dream`.

```bash
for sf in ~/.second-brain/dreams/drm_*/status.json; do
  [ -f "$sf" ] || continue
  status=$(jq -r '.status' "$sf")
  archived=$(jq -r '.archived_at // ""' "$sf")
  if [ "$status" = "completed" ] && [ -z "$archived" -o "$archived" = "null" ]; then
    id=$(jq -r '.id' "$sf")
    added=$(jq -r '.outputs.pages_added // 0' "$sf")
    modified=$(jq -r '.outputs.pages_modified // 0' "$sf")
    echo "  $id — completed, awaiting accept/discard (+$added ~$modified)"
  fi
done
```

### 4. Ungraduated persona signals

Persona signals with `count >= 2` and `graduated == false` are observed-but-not-yet-pinned behaviors. Surface them so the user can graduate via `/second-brain:improve` or pin manually.

```bash
PSFILE=~/.second-brain/persona-signals.jsonl
if [ -f "$PSFILE" ] && [ -s "$PSFILE" ]; then
  jq -c 'select(.count >= 2 and .graduated == false)' "$PSFILE" | while read -r line; do
    cat=$(echo "$line" | jq -r '.category')
    ev=$(echo "$line" | jq -r '.evidence // .text // ""' | head -c 80)
    cnt=$(echo "$line" | jq -r '.count')
    echo "  [$cat] ($cnt×) $ev"
  done
fi
```

### 5. Recent wiki activity

A quick sanity check on the wiki: count of pages and recently-updated entries (last 7d). Helps the user notice whether knowledge is actually accumulating.

```bash
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
WIKI="$KD/wiki"
if [ -d "$WIKI" ]; then
  total=$(find "$WIKI" -name '*.md' -type f ! -name 'index.md' | wc -l | tr -d ' ')
  recent=$(find "$WIKI" -name '*.md' -type f ! -name 'index.md' -mtime -7 | wc -l | tr -d ' ')
  echo "Wiki: ${total} pages, ${recent} updated in last 7d"
fi
```

### 6. Format the output

Combine the sections above into a single review block. Skip empty sections rather than printing "(none)" placeholders. Example shape:

```
# Daily review — 2026-05-13

## Open blockers
### claude-code-plugin
- [active] some blocker

## Stale projects
  old-project — last touched 23d ago

## Pending dreams
  drm_20260510T120000Z — completed, awaiting accept/discard (+3 ~1)

## Persona signals (ungraduated)
  [communication] (2×) prefers terse responses without preamble

## Wiki
Wiki: 12 pages, 3 updated in last 7d
```

Keep it terse. The point is "what needs attention" — not a complete dump.

## Notes

- This skill is read-only. It surfaces state; it doesn't mutate anything.
- If a section has nothing to report, omit the header entirely.
- For action: `/second-brain:improve` graduates signals; `/second-brain:dream` reviews dreams; `pin_to_project` (MCP) or `sb pin project` updates blockers.
