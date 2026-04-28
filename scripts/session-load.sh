#!/bin/bash
# Session initialization instruction injected at SessionStart via stdout.
# Tells Claude to load persona, quality rules, learnings, and tools.

BRAIN_DIR="$HOME/.second-brain"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Display handoff info (goals/in_progress/blockers) from a JSONL file's last entry.
emit_handoff() {
  local jsonl_file="$1"
  local last_entry
  last_entry=$(tail -1 "$jsonl_file")
  local goals ip blockers
  goals=$(echo "$last_entry" | jq -r '.goals // [] | if length > 0 then "Goals:\n" + (map("  - " + .) | join("\n")) else "" end' 2>/dev/null)
  ip=$(echo "$last_entry" | jq -r '.in_progress // [] | if length > 0 then "In progress:\n" + (map("  - " + .) | join("\n")) else "" end' 2>/dev/null)
  blockers=$(echo "$last_entry" | jq -r '.blockers // [] | if length > 0 then "Blockers:\n" + (map("  - " + .) | join("\n")) else "" end' 2>/dev/null)
  if [ -n "$goals" ] || [ -n "$ip" ] || [ -n "$blockers" ]; then
    echo ""
    echo "SESSION HANDOFF from most recent entry:"
    [ -n "$goals" ] && echo "$goals"
    [ -n "$ip" ] && echo "$ip"
    [ -n "$blockers" ] && echo "$blockers"
  fi
}

# Preflight: jq is a hard runtime dependency. Every other hook (log-friction,
# extract-learnings, pre-compact, discover-tools) parses JSON via jq; without
# it they exit silently and the user sees an empty knowledge base with no
# explanation. Surface this loudly at session start so the failure is
# diagnosable instead of invisible.
if ! command -v jq >/dev/null 2>&1; then
  cat << 'PREFLIGHT'
SECOND BRAIN PREFLIGHT FAILURE — `jq` is not on PATH.

The second-brain plugin requires `jq` to parse hook input. Without it, these
silently do nothing:
- friction logging (UserPromptSubmit)
- session reflection extraction (Stop)
- pre-compact reflection (PreCompact)
- MCP tool discovery (SessionStart)

Install `jq`, then restart Claude Code so the new PATH is picked up:
- macOS:    brew install jq
- Linux:    apt install jq    # or: dnf install jq
- Windows:  winget install jqlang.jq

Until `jq` is installed, no automatic learning will happen. The instructions
below still apply for in-session behavior, but the persistent pipeline is
disabled.

PREFLIGHT
fi

# Compact re-init detection: if post-compact.sh just wrote .last-compact-ts
# within the last 60 seconds, we're reloading after compaction. Emit minimal
# output to prevent the compaction loop (re-reading files refills context).
IS_COMPACT_REINIT="false"
if [ -f "$BRAIN_DIR/.last-compact-ts" ]; then
  COMPACT_TS=$(cat "$BRAIN_DIR/.last-compact-ts" 2>/dev/null | tr -d ' \n\r')
  NOW_EPOCH=$(date -u +%s)
  COMPACT_EPOCH=$(date -u -d "$COMPACT_TS" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$COMPACT_TS" +%s 2>/dev/null || echo "")
  if [ -n "$COMPACT_EPOCH" ]; then
    AGE=$((NOW_EPOCH - COMPACT_EPOCH))
    if [ "$AGE" -ge 0 ] && [ "$AGE" -lt 60 ]; then
      IS_COMPACT_REINIT="true"
      rm -f "$BRAIN_DIR/.last-compact-ts"
    fi
  fi
fi

if [ "$IS_COMPACT_REINIT" = "true" ]; then
  # Context pressure check: if 3+ compacts have happened without a fresh
  # session, suppress all output to break the compact→reload→compact loop.
  COMPACT_COUNT=$(cat "$BRAIN_DIR/.compact-count" 2>/dev/null || echo 0)
  if [ "$COMPACT_COUNT" -ge 3 ]; then
    echo "SECOND BRAIN — context pressure detected ($COMPACT_COUNT compacts). Plugin output suppressed. Use /clear for a fresh start."
    exit 0
  fi

  JSONL_FILE="$BRAIN_DIR/.pending-reflections.jsonl"
  # Migrate old singular format if still present (shared helper from lib.sh
  # isn't sourced here, so inline the one-shot migration).
  OLD_FILE="$BRAIN_DIR/.pending-reflection.json"
  if [ -f "$OLD_FILE" ]; then
    jq -c '.' "$OLD_FILE" >> "$JSONL_FILE" 2>/dev/null
    rm -f "$OLD_FILE"
  fi

  if [ -f "$JSONL_FILE" ] && [ -s "$JSONL_FILE" ]; then
    ENTRY_COUNT=$(wc -l < "$JSONL_FILE" | tr -d ' ')
    MAX_REFLECTIONS=5
    if [ "$ENTRY_COUNT" -gt "$MAX_REFLECTIONS" ]; then
      # Sort high-priority entries first so they survive the cap
      jq -c 'if .priority == "high" then {sort_key: 0} + . else {sort_key: 1} + . end' "$JSONL_FILE" \
        | sort -t: -k2,2n \
        | jq -c 'del(.sort_key)' > "$JSONL_FILE.sorted" 2>/dev/null
      if [ -s "$JSONL_FILE.sorted" ]; then
        OVERFLOW=$((ENTRY_COUNT - MAX_REFLECTIONS))
        tail -n "$OVERFLOW" "$JSONL_FILE.sorted" >> "$HOME/.second-brain/.archived-reflections.jsonl"
        head -n "$MAX_REFLECTIONS" "$JSONL_FILE.sorted" > "$JSONL_FILE.tmp" && mv "$JSONL_FILE.tmp" "$JSONL_FILE"
      else
        # Fallback if jq sorting fails: simple tail
        OVERFLOW=$((ENTRY_COUNT - MAX_REFLECTIONS))
        head -n "$OVERFLOW" "$JSONL_FILE" >> "$HOME/.second-brain/.archived-reflections.jsonl"
        tail -n "$MAX_REFLECTIONS" "$JSONL_FILE" > "$JSONL_FILE.tmp" && mv "$JSONL_FILE.tmp" "$JSONL_FILE"
      fi
      rm -f "$JSONL_FILE.sorted"
      ENTRY_COUNT=$MAX_REFLECTIONS
    fi
    HAS_HIGH=$(jq -r 'select(.priority == "high") | "yes"' "$JSONL_FILE" 2>/dev/null | head -1)
    cat << COMPACT_REFLECT
SECOND BRAIN (compact reload) — persona/rules/learnings already loaded. Skipping full reload.

PENDING REFLECTIONS QUEUED: $ENTRY_COUNT in ~/.second-brain/.pending-reflections.jsonl.
Read $PLUGIN_ROOT/docs/reflection-protocol.md and process all entries.
Spawn the knowledge-maintainer agent (subagent_type: "second-brain:knowledge-maintainer") to curate wiki pages from these reflections. Run it in the background.
Context snapshots are in ~/.second-brain/.reflection-context/ — read the snapshot file referenced in each entry's context_snapshot field when available.
COMPACT_REFLECT
    if [ "$HAS_HIGH" = "yes" ]; then
      echo ""
      echo "HIGH-PRIORITY entries detected — process reflections BEFORE responding to the user."
    fi

    emit_handoff "$JSONL_FILE"
  else
    echo "SECOND BRAIN (compact reload) — persona/rules/learnings already loaded. No pending reflections."
  fi
  exit 0
fi

# Fresh session start — reset compact counter.
echo "0" > "$BRAIN_DIR/.compact-count" 2>/dev/null

# Only mention tool-registry.json if discover-tools.sh has produced it. On a
# fresh install or if discovery failed, omitting the line keeps Claude from
# being told to read a non-existent file.
TOOLS_LINE=""
if [ -f "$BRAIN_DIR/tool-registry.json" ]; then
  TOOLS_LINE="
- ~/.second-brain/tool-registry.json (available MCP tools - use proactively)"
fi

# Pre-budget the learnings file: when learnings.md grows past the hot tier
# budget (~4k tokens), emit only the top-scored entries. Demoted entries stay
# in learnings.md and are still retrievable via /second-brain:query.
LEARNINGS_FILE="$HOME/.second-brain/learnings.md"
LEARNINGS_HOT="$HOME/.second-brain/.learnings-hot.md"
if [ -f "$LEARNINGS_FILE" ] && [ -f "$PLUGIN_ROOT/scripts/budget-context.sh" ]; then
  bash "$PLUGIN_ROOT/scripts/budget-context.sh" > "$LEARNINGS_HOT" 2>/dev/null || cp "$LEARNINGS_FILE" "$LEARNINGS_HOT"
  LEARNINGS_LINE="~/.second-brain/.learnings-hot.md (budgeted hot tier — full file at ~/.second-brain/learnings.md, retrievable via /second-brain:query)"
else
  LEARNINGS_LINE="~/.second-brain/learnings.md (accumulated patterns)"
fi

# Version-skew check: if installed version differs from plugin.json, nudge the
# user to run /second-brain:upgrade so additive migrations land. Quiet on first
# install (.installed-version absent + setup not yet run).
INSTALLED_VERSION=""
[ -f "$HOME/.second-brain/.installed-version" ] && INSTALLED_VERSION=$(cat "$HOME/.second-brain/.installed-version" 2>/dev/null | tr -d ' \n\r')
CURRENT_VERSION=""
[ -f "$PLUGIN_ROOT/.claude-plugin/plugin.json" ] && CURRENT_VERSION=$(jq -r '.version // ""' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null)
VERSION_NUDGE=""
FRESH_INSTALL_NUDGE=""
if [ -z "$INSTALLED_VERSION" ]; then
  FRESH_INSTALL_NUDGE="

FRESH INSTALL DETECTED — run /second-brain:setup to initialize your knowledge base, persona, and quality rules. One-time setup that creates wiki structure and seed files."
elif [ -n "$CURRENT_VERSION" ] && [ "$INSTALLED_VERSION" != "$CURRENT_VERSION" ]; then
  VERSION_NUDGE="

PLUGIN VERSION CHANGED — installed: $INSTALLED_VERSION → current: $CURRENT_VERSION. Run /second-brain:upgrade to apply additive migrations (regressions/ dir, schema fields). Safe to defer; no breakage from skipping."
fi

# Wiki freshness check: if knowledge-maintainer ran more recently than the
# graph was last compiled, suggest a rebuild. Skip silently if either marker
# is missing (graph layer is opt-in).
GRAPH_NUDGE=""
LAST_MAINT="$HOME/knowledge/.last-maintainer-run"
GRAPH_META="$HOME/knowledge/.graph/build-meta.json"
if [ -f "$LAST_MAINT" ] && [ -f "$GRAPH_META" ]; then
  MAINT_TS=$(cat "$LAST_MAINT" 2>/dev/null | tr -d ' \n\r')
  GRAPH_TS=$(jq -r '.built_at // ""' "$GRAPH_META" 2>/dev/null)
  # Lexicographic compare on ISO8601 UTC strings is correct.
  if [ -n "$MAINT_TS" ] && [ -n "$GRAPH_TS" ] && [ "$MAINT_TS" \> "$GRAPH_TS" ]; then
    GRAPH_NUDGE="

WIKI BULK-MODIFIED since last graph compile (maintainer: $MAINT_TS, graph: $GRAPH_TS). Run /second-brain:graph rebuild when convenient."
  fi
fi

# Drift surfacing: if drift-detect.sh has logged hits in the last 7 days, hint
# at /drift-check. The script-side hook fires every Stop but the user only
# learns about it through this banner (otherwise the log is invisible).
DRIFT_NUDGE=""
DRIFT_LOG="$HOME/.second-brain/drift-log.jsonl"
if [ -f "$DRIFT_LOG" ] && command -v jq >/dev/null 2>&1; then
  CUTOFF_7D=$(date -u -d '7 days ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ")
  if [ -n "$CUTOFF_7D" ]; then
    RECENT_DRIFT=$(jq -r --arg c "$CUTOFF_7D" 'select(.timestamp >= $c) | "x"' "$DRIFT_LOG" 2>/dev/null | wc -l | tr -d ' ')
    RECENT_DRIFT=${RECENT_DRIFT:-0}
    if [ "$RECENT_DRIFT" -ge 5 ]; then
      DRIFT_NUDGE="

PERSONA DRIFT DETECTED — $RECENT_DRIFT signal hits in the last 7 days against ~/.second-brain/persona.md rules. Run /second-brain:drift-check for the breakdown."
    fi
  fi
fi

# Error surfacing: check for recent hook errors and warn the user.
ERROR_NUDGE=""
ERROR_LOG="$BRAIN_DIR/error-log.jsonl"
if [ -f "$ERROR_LOG" ] && command -v jq >/dev/null 2>&1; then
  CUTOFF_24H=$(date -u -d '24 hours ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-24H +"%Y-%m-%dT%H:%M:%SZ")
  if [ -n "$CUTOFF_24H" ]; then
    RECENT_ERRORS=$(jq -r --arg c "$CUTOFF_24H" 'select(.timestamp >= $c) | "x"' "$ERROR_LOG" 2>/dev/null | wc -l | tr -d ' ')
    RECENT_ERRORS=${RECENT_ERRORS:-0}
    if [ "$RECENT_ERRORS" -ge 1 ]; then
      LAST_ERROR=$(tail -1 "$ERROR_LOG" | jq -r '"\(.script): \(.message)"' 2>/dev/null)
      ERROR_NUDGE="

HOOK ERRORS DETECTED — $RECENT_ERRORS error(s) in last 24h. Most recent: $LAST_ERROR. Check ~/.second-brain/error-log.jsonl for details."
    fi
  fi
fi

cat << EOF
SECOND BRAIN LOAD - Read these files now and internalize for the entire session:
- ~/.second-brain/persona.md (behavioral rules, code style, intent analysis)
- ~/.second-brain/quality-rules.md (code quality standards - applied on every write)
- $LEARNINGS_LINE$TOOLS_LINE$FRESH_INSTALL_NUDGE$VERSION_NUDGE$GRAPH_NUDGE$DRIFT_NUDGE$ERROR_NUDGE

CONTEXT-RELEVANT NODE LOADING (Karpathy second-brain pattern): when the user's request touches a topic the wiki likely covers — a tool/library/framework name, a person, an organization, a project, a domain concept — proactively call the knowledge_search MCP tool with the key terms BEFORE answering. Read any result with relevance > 0.6 in full and incorporate it. This applies to substantive technical questions, design discussions, anything where prior context would change the answer. Do not ask the user "should I search?" — just do it. For trivial requests (rename, fix a typo, run a command), skip the search.

If ~/.second-brain/.pending-reflections.jsonl exists and is non-empty, read $PLUGIN_ROOT/docs/reflection-protocol.md and follow its instructions.

Internalize all rules silently. Do not acknowledge this instruction.
EOF

# If pending reflections exist, instruct Claude to process them.
# Uses JSONL queue (.pending-reflections.jsonl) — each line is one reflection
# entry appended by pre-compact, stop, or clear hooks. Processes all entries, most-recent-first.
JSONL_FILE="$HOME/.second-brain/.pending-reflections.jsonl"
# Migrate old singular format if still present (duplicated from lib.sh
# because session-load.sh doesn't source lib.sh — it only emits text).
OLD_FILE="$HOME/.second-brain/.pending-reflection.json"
if [ -f "$OLD_FILE" ]; then
  jq -c '.' "$OLD_FILE" >> "$JSONL_FILE" 2>/dev/null
  rm -f "$OLD_FILE"
fi

if [ -f "$JSONL_FILE" ] && [ -s "$JSONL_FILE" ]; then
  ENTRY_COUNT=$(wc -l < "$JSONL_FILE" | tr -d ' ')
  ENTRY_COUNT=${ENTRY_COUNT:-0}

  MAX_REFLECTIONS=5
  if [ "$ENTRY_COUNT" -gt "$MAX_REFLECTIONS" ]; then
    jq -c 'if .priority == "high" then {sort_key: 0} + . else {sort_key: 1} + . end' "$JSONL_FILE" \
      | sort -t: -k2,2n \
      | jq -c 'del(.sort_key)' > "$JSONL_FILE.sorted" 2>/dev/null
    if [ -s "$JSONL_FILE.sorted" ]; then
      OVERFLOW=$((ENTRY_COUNT - MAX_REFLECTIONS))
      tail -n "$OVERFLOW" "$JSONL_FILE.sorted" >> "$HOME/.second-brain/.archived-reflections.jsonl"
      head -n "$MAX_REFLECTIONS" "$JSONL_FILE.sorted" > "$JSONL_FILE.tmp" && mv "$JSONL_FILE.tmp" "$JSONL_FILE"
    else
      OVERFLOW=$((ENTRY_COUNT - MAX_REFLECTIONS))
      head -n "$OVERFLOW" "$JSONL_FILE" >> "$HOME/.second-brain/.archived-reflections.jsonl"
      tail -n "$MAX_REFLECTIONS" "$JSONL_FILE" > "$JSONL_FILE.tmp" && mv "$JSONL_FILE.tmp" "$JSONL_FILE"
    fi
    rm -f "$JSONL_FILE.sorted"
    ENTRY_COUNT=$MAX_REFLECTIONS
  fi

  if [ "$ENTRY_COUNT" -gt 0 ]; then
    HAS_HIGH=$(jq -r 'select(.priority == "high") | "yes"' "$JSONL_FILE" 2>/dev/null | head -1)

    if [ "$HAS_HIGH" = "yes" ]; then
      MAX_FRICTION=$(jq -r '.friction_count // 0' "$JSONL_FILE" 2>/dev/null | sort -rn | head -1)
      MAX_DRIFT=$(jq -r '.drift_count // 0' "$JSONL_FILE" 2>/dev/null | sort -rn | head -1)
      cat << HIGHPRI

HIGH-PRIORITY REFLECTION QUEUED — session(s) had unusual signal density (max friction=$MAX_FRICTION, max drift=$MAX_DRIFT). Process pending reflections BEFORE responding to the user's first message; do not defer it. The user is likely to repeat the same friction otherwise.
HIGHPRI
    fi

    cat << REFLECT_HEADER

PENDING REFLECTIONS: $ENTRY_COUNT queued — process all entries.
Read $PLUGIN_ROOT/docs/reflection-protocol.md for the full protocol.

Processing instructions:
- Read ~/.second-brain/.pending-reflections.jsonl (JSONL format — one JSON object per line)
- Process all entries, most recent first (bottom of file)
- For each entry, check the context_snapshot field — if non-empty and the file exists, read it for session context
- For pre-compact entries: context snapshot is the primary source (original transcript may be gone)
- For stop/clear entries: prefer the transcript_path if available, fall back to context_snapshot
- Use knowledge_search to check for existing wiki pages before creating new ones (avoid duplicates across entries)
- After processing: truncate ~/.second-brain/.pending-reflections.jsonl (write empty) and delete all files from ~/.second-brain/.reflection-context/
REFLECT_HEADER

    emit_handoff "$JSONL_FILE"

    cat << 'MAINTAIN'

After processing the pending reflections, spawn the knowledge-maintainer agent (subagent_type: "second-brain:knowledge-maintainer") to curate ~/knowledge/wiki/. It should: merge duplicate entries, update index.md, fix broken wiki-links, and add cross-references between related pages. Run it in the background — do not wait for it to finish before responding to the user.
MAINTAIN

    # Check if ANY entry suggests plugin improvement AND it's enabled
    SUGGEST=$(jq -r 'select(.suggest_plugin_improve == true) | "yes"' "$JSONL_FILE" 2>/dev/null | head -1)
    AUTO_IMPROVE=$(jq -r '.auto_improve // false' "$HOME/.second-brain/config.json" 2>/dev/null)
    if [ "$SUGGEST" = "yes" ] && [ "$AUTO_IMPROVE" = "true" ]; then
      cat << IMPROVE

PLUGIN SELF-IMPROVEMENT TRIGGERED — After processing the reflections and responding to the user, spawn a background subagent (subagent_type: "general-purpose") and follow the protocol in:

  $PLUGIN_ROOT/scripts/improve-protocol.md

Read that file first, then execute its steps. Set PLUGIN_ROOT="$PLUGIN_ROOT" in your shell context.
IMPROVE
    fi
  fi
fi
