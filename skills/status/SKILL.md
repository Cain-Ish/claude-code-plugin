---
name: status
description: Show second-brain hot-tier and wiki health at a glance. Reports USER.md size, active PROJECT.md size, projects.jsonl project count, wiki page counts per category, and index.md status.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Bash(git rev-parse:*) Bash(basename *) Bash(wc *) Bash(cat *) Bash(ls *) Bash(test *) Bash(jq *) Bash(date *) Bash(find *) Bash(grep *) Bash(bash *) Bash(printf *) Bash(tr *) mcp__knowledge-base__knowledge_stats mcp__knowledge-base__persona_stats
---

<!-- user instruction verbatim: "1" -->

# Status

Show a compact dashboard of the v1.0 second-brain state: the hot tier (USER.md + active PROJECT.md + projects.jsonl) plus the cold tier (wiki page counts per category).

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
INDEX_FILE=~/.second-brain/projects.jsonl

U=0; P=0
[ -f "$USER_FILE" ]    && U=$(wc -c < "$USER_FILE" | tr -d ' ')
[ -f "$PROJECT_FILE" ] && P=$(wc -c < "$PROJECT_FILE" | tr -d ' ')

echo "USER.md:    ${U} bytes"
echo "PROJECT.md ($SLUG): ${P} bytes"
echo "Combined:   $((U + P)) bytes (cap ≈ 3200)"
```

If the combined size exceeds ~3200 bytes, flag it — the hot tier is meant to stay small and always-loaded.

### 3. Index.txt project count

`projects.jsonl` is JSONL; one record per registered project (see `setup` skill for the schema).

```bash
COUNT=0
[ -f "$INDEX_FILE" ] && COUNT=$(grep -c '"slug"' "$INDEX_FILE" 2>/dev/null || true)
echo "Registered projects: ${COUNT}"
```

If the active `$SLUG` is not in `projects.jsonl`, surface that — the user probably should run `/second-brain:setup`.

### 4. Wiki page counts per category

Prefer the `knowledge_stats` MCP tool when available — it reads the wiki tree directly and returns a formatted breakdown:

```
knowledge_stats()
```

If the MCP tool is unavailable, fall back to a direct filesystem scan. Resolve the knowledge dir from the env var Claude Code injects per userConfig (skill-body `${user_config.X}` placeholders DO NOT expand in bash):

```bash
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
for dir in "$KD"/wiki/*/; do
  [ -d "$dir" ] || continue
  name=$(basename "$dir")
  N=$(find "$dir" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | wc -l | tr -d ' ')
  echo "  ${name}: ${N}"
done
# Also check for index.md
if [ -f "$KD/wiki/index.md" ]; then
  echo "  index.md: present"
else
  echo "  index.md: MISSING (run knowledge_reindex)"
fi
```

### 4b. Wiki health check

Run `knowledge_validate` MCP tool if available to detect issues:

```
knowledge_validate()
```

If unavailable, skip — validation also runs automatically during `knowledge_reindex` and on session start via `ensure-dirs.sh`.

### 4c. Persona signal stats

Report accumulated persona signals and any ready for graduation:

```bash
PSFILE=~/.second-brain/persona-signals.jsonl
if [ -f "$PSFILE" ] && [ -s "$PSFILE" ]; then
  TOTAL=$(wc -l < "$PSFILE" | tr -d ' ')
  READY=$(jq -c 'select(.count >= 3 and .graduated == false)' "$PSFILE" 2>/dev/null | wc -l | tr -d ' ')
  GRADUATED=$(jq -c 'select(.graduated == true)' "$PSFILE" 2>/dev/null | wc -l | tr -d ' ')
  echo "Persona signals: ${TOTAL} tracked, ${READY} ready to graduate, ${GRADUATED} graduated"
else
  echo "Persona signals: none yet"
fi
```

If signals are ready to graduate (count ≥ 3, not yet graduated), nudge the user to run `/second-brain:improve`.

### 4d. Dream status

Report active or recent dream state:

```bash
DREAMS_DIR=~/.second-brain/dreams
if [ -d "$DREAMS_DIR" ]; then
  for sf in "$DREAMS_DIR"/drm_*/status.json; do
    [ -f "$sf" ] || continue
    DID=$(jq -r '.id' "$sf" 2>/dev/null)
    DSTATUS=$(jq -r '.status' "$sf" 2>/dev/null)
    DARCHIVED=$(jq -r '.archived_at // ""' "$sf" 2>/dev/null)
    [ "$DARCHIVED" != "" ] && [ "$DARCHIVED" != "null" ] && continue
    DA=$(jq -r '.outputs.pages_added // 0' "$sf" 2>/dev/null)
    DM=$(jq -r '.outputs.pages_modified // 0' "$sf" 2>/dev/null)
    DR=$(jq -r '.outputs.pages_removed // 0' "$sf" 2>/dev/null)
    echo "Dream $DID: $DSTATUS (+$DA ~$DM -$DR)"
  done
fi
```

If a dream is `completed`, nudge the user to run `/second-brain:dream` to review and accept/discard. If `running`, show elapsed time. If no active dreams, report "No active dreams."

### 4e. Native auto-memory (the OTHER memory system)

Claude Code ships a built-in auto-memory that writes its OWN per-repo
`MEMORY.md` (separate from the second-brain's `~/.second-brain` + `~/knowledge`).
It's ON by default. Surface its state ALWAYS — whether on or off — so the user
can see both memory writers and decide whether the second-brain should be the
single source of truth. The shared detector lives in `lib.sh`:

Parse the detector's `key=value` output with `grep`/`cut` — **never `eval`** it
(the `path` field derives from `settings.json`, a trust boundary; `eval` on
settings-derived data is a code-injection vector — the detector sanitizes too):

```bash
AM=$(bash -c 'source "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/scripts/lib.sh"; sb_auto_memory_state' 2>/dev/null)
am() { printf '%s\n' "$AM" | grep -E "^$1=" | head -1 | cut -d= -f2-; }
if [ "$(am state)" = "on" ]; then
  echo "Native auto-memory: ON ($(am reason))"
  echo "  store: $(am path) ($(am files) files, MEMORY.md $(am memory_lines) lines)"
  echo "  note: two memory systems are active. To make second-brain the single"
  echo "        source of truth, disable native auto-memory:"
  echo "          export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1   # per shell/session"
  echo "          # or in settings.json:  \"autoMemoryEnabled\": false"
  echo "        Leave both on to keep native's scratchpad alongside."
else
  echo "Native auto-memory: OFF ($(am reason)) — second-brain is the sole memory writer."
fi
```

This is informational only. The skill NEVER edits settings or exports env —
disabling a Claude Code built-in is the user's per-machine choice. (Detector:
`sb_auto_memory_state` in `scripts/lib.sh`; design:
docs/specs/2026-05-29-auto-memory-coordination-design.md.)

### 5. Pending PROJECT.md update flag

If the Stop-hook predicate fired in a recent session, a flag file is left for the next session to act on. Surface it so the user knows there is queued reflection work.

```bash
FLAG=~/.second-brain/.project-update-pending-"$SLUG"
if [ -f "$FLAG" ]; then
  echo "Pending PROJECT.md update flagged for $SLUG (run /second-brain:improve to apply)."
fi
```

### 5b. Persona state

Surface the persona core's live state — identity card size, dismissals 7d, today's persona spend vs daily budget cap. Read-only; nothing here mutates.

```bash
PCARD=~/.second-brain/persona-card.md
if [ -f "$PCARD" ]; then
  echo "Persona card: $(wc -l < "$PCARD" | tr -d ' ') lines, $(wc -c < "$PCARD" | tr -d ' ') bytes"
else
  echo "Persona card: MISSING (run /second-brain:setup to seed)"
fi

DISMISSAL_FILE=~/.second-brain/.persona-dismissals.jsonl
DISMISSALS_7D=0
if [ -f "$DISMISSAL_FILE" ]; then
  CUTOFF=$(date -u -d '7 days ago' +%s 2>/dev/null || date -u -v -7d +%s 2>/dev/null)
  if [ -n "$CUTOFF" ]; then
    DISMISSALS_7D=$(jq -c --argjson cutoff "$CUTOFF" '
      select((.at | fromdateiso8601) > $cutoff)' "$DISMISSAL_FILE" 2>/dev/null | wc -l | tr -d ' ')
  fi
fi
echo "Persona dismissals (7d): $DISMISSALS_7D"

BUDGET_FILE=~/.second-brain/persona-budget.json
TODAY=$(date -u +%Y-%m-%d)
SPEND=0
if [ -f "$BUDGET_FILE" ]; then
  B_DATE=$(jq -r '.date // ""' "$BUDGET_FILE" 2>/dev/null)
  if [ "$B_DATE" = "$TODAY" ]; then
    SPEND=$(jq -r '.today_usd // 0' "$BUDGET_FILE" 2>/dev/null)
  fi
fi
CAP="${SB_PERSONA_DAILY_BUDGET:-20}"
printf "Persona spend today: \$%.4f / \$%s\n" "$SPEND" "$CAP"

CATALOG=~/.second-brain/.installed-catalog.json
if [ -f "$CATALOG" ]; then
  P=$(jq -r '.plugins | length' "$CATALOG" 2>/dev/null)
  A=$(jq -r '.agents | length' "$CATALOG" 2>/dev/null)
  S=$(jq -r '.skills | length' "$CATALOG" 2>/dev/null)
  echo "Installed catalog: ${P} plugins, ${A} agents, ${S} skills"
else
  echo "Installed catalog: not yet built (runs at SessionStart)"
fi
```

If `Persona dismissals (7d)` is above 3, the persona core auto-mutes its opinionated framing — that's the backoff working. If spend is approaching cap, deeper analyses (`/?` and `/second-brain:think`) start returning `budget_skipped`.

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

## Persona
- Signals: 5 tracked, 1 ready to graduate, 2 graduated

## Native auto-memory (Claude Code built-in)
- ON (default-on) — store: ~/.claude/projects/<repo>/memory/ (5 files, MEMORY.md 38 lines)
- note: two memory systems active; disable via CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 to make second-brain sole writer

## Pending
- (none)
```

Keep the output terse. No reflection-pipeline metrics — `learnings.md`, `friction-log.jsonl`, `quality-rules.md`, `persona.md`, and `tool-registry.json` no longer exist. `error-log.jsonl` is not dumped here, but `verify.sh` (Step 6) flags new entries since the last successful verify. If the user wants deep reflection on the current session, point them at `/second-brain:improve`.
