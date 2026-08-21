---
name: status
description: Show second-brain hot-tier and wiki health at a glance. Reports USER.md size, active PROJECT.md size, projects.jsonl project count, wiki page counts per category, and index.md status.
# 0.33.24 skill-catalog diet: user slash command only — model-invocation disabled
# (dashboards being model-invocable contradicted the silence-default principle).
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Bash(git rev-parse:*) Bash(basename *) Bash(wc *) Bash(cat *) Bash(ls *) Bash(test *) Bash(jq *) Bash(date *) Bash(find *) Bash(grep *) Bash(bash *) Bash(printf *) Bash(tr *) mcp__plugin_second-brain_knowledge-base__knowledge_stats mcp__plugin_second-brain_knowledge-base__knowledge_validate mcp__plugin_second-brain_knowledge-base__persona_stats
---

# Status

Show a compact dashboard of the v1.0 second-brain state: the hot tier (USER.md + active PROJECT.md + projects.jsonl) plus the cold tier (wiki page counts per category).

## Steps

### 1. Resolve the active project

```bash
# Monorepo-aware detection (same idiom as the setup skill): source lib.sh for sb_detect_project.
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
_det=$(sb_detect_project "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
IFS=$'\t' read -ra _det_fields <<< "$_det"
SLUG="${_det_fields[0]:-}"
echo "Active project: $SLUG"
```

### 2. Hot-tier sizes

Report byte counts for each hot-tier file. Size contract lives in the `setup` skill (single home): USER.md targets ~3200 B; SessionStart emit caps are 6000 B (USER) / 3000 B (PROJECT) inside the 8000 B injection budget.

```bash
USER_FILE=~/.second-brain/USER.md
PROJECT_FILE=~/.second-brain/projects/"$SLUG"/PROJECT.md
INDEX_FILE=~/.second-brain/projects.jsonl

U=0; P=0
[ -f "$USER_FILE" ]    && U=$(wc -c < "$USER_FILE" | tr -d ' ')
[ -f "$PROJECT_FILE" ] && P=$(wc -c < "$PROJECT_FILE" | tr -d ' ')

echo "USER.md:    ${U} bytes (target ≈ 3200)"
echo "PROJECT.md ($SLUG): ${P} bytes (emit cap 3000)"
```

If USER.md exceeds ~3200 bytes, flag it — the hot tier is meant to stay small and always-loaded (caps: see the `setup` skill's size contract).

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

### 4b2. Embeddings coverage

One line: what fraction of indexed episodic exchanges have vectors. 100% =
healthy; anything less means vector recall silently misses those exchanges
(the next session-end extraction backfills them when the deps are linked —
SessionStart auto-relinks a missing cache symlink).

```bash
EPI=${BRAIN_DIR:-$HOME/.second-brain}/episodic-index.json
if [ -f "$EPI" ]; then
  jq -r '(.exchanges|length) as $t
    | ([.exchanges[] | select((.embedding|length) > 0)] | length) as $e
    | if $t == 0 then "Embeddings: no exchanges indexed yet"
      else "Embeddings coverage: \($e)/\($t) exchanges (\(($e * 100 / $t) | floor)%)" end' "$EPI"
fi
```

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

Graduation is automatic: `merge-persona-signals.sh` (Stop hook) auto-pins count≥2 high-confidence signals to USER.md. If ungraduated signals linger here, offer to pin them explicitly via the `pin_to_user` MCP tool.

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
`sb_auto_memory_state` in `scripts/lib.sh`; design history on the
`archive/docs` branch: `git show archive/docs:docs/specs/2026-05-29-auto-memory-coordination-design.md`.)

### 5. Persona state

Surface the persona core's live state — identity card size, dismissals 7d, installed catalog. Read-only; nothing here mutates.

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

If `Persona dismissals (7d)` is above 3, the persona core auto-mutes its opinionated framing — that's the backoff working.

### 6. Runtime smoke check

Run `verify.sh` to surface live-state issues that the static validator can't see (missing files, oversized hot tier, stale errors). Print its output verbatim — verify owns its own format.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify.sh"
```

The script exits 0 with `verify: ok` when everything is healthy, or exits non-zero with one `verify: FAIL:` line per failed check. Do not auto-remediate — point the user at the relevant skill (`/second-brain:setup` for missing files, `/second-brain:maintain` for an oversized hot tier — its Phase 0 is hot-tier hygiene) and let them act.

### 6b. Hook latency (R7 telemetry)

The hook-timer wrapper logs `{kind:"latency", hook, duration_ms}` lines to
the audit-log for the heavy hooks (session-load, persona-context,
stop-extract, pre-compact, dream-autostage). Render p50/p95 per hook plus any
budget warnings — the R1 timeout class (24s stacks vs 25s ceilings) becomes
visible here BEFORE it turns into ec=124 failures:

```bash
AUD="$HOME/.second-brain/audit-log.jsonl"
if [ -f "$AUD" ] && grep -q '"kind":"latency"' "$AUD" 2>/dev/null; then
  grep '"kind":"latency"' "$AUD" | tail -500 \
    | jq -r '[.hook, .duration_ms] | @tsv' 2>/dev/null \
    | sort | awk -F'\t' '
      { v[$1] = v[$1] " " $2; n[$1]++ }
      END {
        for (h in n) {
          split(substr(v[h], 2), a, " "); m = n[h]
          # values arrive sorted per hook only if input sorted by hook+num; sort here
          for (i = 1; i < m; i++) for (j = i + 1; j <= m; j++)
            if (a[i] + 0 > a[j] + 0) { t = a[i]; a[i] = a[j]; a[j] = t }
          p50 = a[int((m + 1) * 0.50)]; p95 = a[int((m + 1) * 0.95)]
          if (p50 == "") p50 = a[m]; if (p95 == "") p95 = a[m]
          printf "  %-22s p50=%sms p95=%sms (n=%d)\n", h, p50, p95, m
        }
      }'
  WARNS=$(grep -c '"budget_warn":true' "$AUD" 2>/dev/null || echo 0)
  [ "$WARNS" -gt 0 ] && echo "  ⚠ $WARNS run(s) exceeded 70% of their hook budget — check which hook above is near its hooks.json timeout"
else
  echo "  (no latency telemetry yet — lands after the first wrapped-hook run on >=0.24.46)"
fi
```

### 7. Present the dashboard

Format as a clean block. Example:

```
# Second-brain status

## Active project
- slug: claude-code-plugin

## Hot tier
- USER.md:    420 bytes (target ~3200)
- PROJECT.md: 1180 bytes (emit cap 3000)
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
```

Keep the output terse. No reflection-pipeline metrics — `learnings.md`, `friction-log.jsonl`, `quality-rules.md`, `persona.md`, and `tool-registry.json` no longer exist. `error-log.jsonl` is not dumped here, but `verify.sh` (Step 6) flags new entries since the last successful verify. Deep session reflection is automatic now — Stop-hook extraction plus dream consolidation (`/second-brain:dream`); explicit pins go through the `pin_to_user`/`pin_to_project` MCP tools.
