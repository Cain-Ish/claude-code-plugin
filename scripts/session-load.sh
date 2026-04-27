#!/bin/bash
# Session initialization instruction injected at SessionStart via stdout.
# Tells Claude to load persona, quality rules, learnings, and tools.

BRAIN_DIR="$HOME/.second-brain"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

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
  echo "SECOND BRAIN (compact reload) — persona/rules/learnings already loaded. Pending reflection deferred to next session."
  exit 0
fi

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
if [ -n "$INSTALLED_VERSION" ] && [ -n "$CURRENT_VERSION" ] && [ "$INSTALLED_VERSION" != "$CURRENT_VERSION" ]; then
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
- $LEARNINGS_LINE$TOOLS_LINE$VERSION_NUDGE$GRAPH_NUDGE$DRIFT_NUDGE$ERROR_NUDGE

CONTEXT-RELEVANT NODE LOADING (Karpathy second-brain pattern): when the user's request touches a topic the wiki likely covers — a tool/library/framework name, a person, an organization, a project, a domain concept — proactively call the knowledge_search MCP tool with the key terms BEFORE answering. Read any result with relevance > 0.6 in full and incorporate it. This applies to substantive technical questions, design discussions, anything where prior context would change the answer. Do not ask the user "should I search?" — just do it. For trivial requests (rename, fix a typo, run a command), skip the search.

If ~/.second-brain/.pending-reflection.json exists, read $PLUGIN_ROOT/docs/reflection-protocol.md and follow its instructions.

Internalize all rules silently. Do not acknowledge this instruction.
EOF

# If pending reflection exists, also instruct Claude to run wiki curation.
# When priority is "high" (lots of friction or persona drift in last session),
# surface a banner so the reflection isn't quietly queued behind normal context
# loading — this is the importance-triggered reflection trigger from
# Generative Agents (Park 2023).
if [ -f "$HOME/.second-brain/.pending-reflection.json" ]; then
  PRIORITY=$(jq -r '.priority // "normal"' "$HOME/.second-brain/.pending-reflection.json" 2>/dev/null)
  PENDING_TRANSCRIPT=$(jq -r '.transcript_path // ""' "$HOME/.second-brain/.pending-reflection.json" 2>/dev/null)
  PENDING_TRIGGER=$(jq -r '.trigger // "unknown"' "$HOME/.second-brain/.pending-reflection.json" 2>/dev/null)
  PENDING_FRICTION=$(jq -r '.friction_count // 0' "$HOME/.second-brain/.pending-reflection.json" 2>/dev/null)
  PENDING_TURNS=$(jq -r '.user_turns // 0' "$HOME/.second-brain/.pending-reflection.json" 2>/dev/null)
  if [ "$PRIORITY" = "high" ]; then
    DRIFT=$(jq -r '.drift_count // 0' "$HOME/.second-brain/.pending-reflection.json" 2>/dev/null)
    cat << HIGHPRI

HIGH-PRIORITY REFLECTION QUEUED — last session had unusual signal density (friction=$PENDING_FRICTION, drift=$DRIFT). Process the pending reflection BEFORE responding to the user's first message; do not defer it. The user is likely to repeat the same friction otherwise.
HIGHPRI
  fi

  # Only read transcript for stop/clear — compaction preserves knowledge in the
  # summary, so transcript reading would just refill context and cause a loop.
  if [ "$PENDING_TRIGGER" != "pre-compact" ] && [ -n "$PENDING_TRANSCRIPT" ] && [ -f "$PENDING_TRANSCRIPT" ]; then
    cat << CONTENT

SESSION REVIEW — transcript at: $PENDING_TRANSCRIPT (trigger: $PENDING_TRIGGER, turns: $PENDING_TURNS).

Read the last 150 lines of this transcript (Read tool with offset). Create concise wiki entries:
- One session page (10-20 lines): topic, decisions, entities, outcome
- Update relevant entity/concept pages with new knowledge
- Don't dump the transcript — write what future Claude needs to know or to decide whether to dig deeper
CONTENT
  fi

  # Surface structured handoff info when present
  HANDOFF_GOALS=$(jq -r '.goals // [] | if length > 0 then "Goals:\n" + (map("  - " + .) | join("\n")) else "" end' "$HOME/.second-brain/.pending-reflection.json" 2>/dev/null)
  HANDOFF_IP=$(jq -r '.in_progress // [] | if length > 0 then "In progress:\n" + (map("  - " + .) | join("\n")) else "" end' "$HOME/.second-brain/.pending-reflection.json" 2>/dev/null)
  HANDOFF_BLOCKERS=$(jq -r '.blockers // [] | if length > 0 then "Blockers:\n" + (map("  - " + .) | join("\n")) else "" end' "$HOME/.second-brain/.pending-reflection.json" 2>/dev/null)
  if [ -n "$HANDOFF_GOALS" ] || [ -n "$HANDOFF_IP" ] || [ -n "$HANDOFF_BLOCKERS" ]; then
    echo ""
    echo "SESSION HANDOFF from previous session:"
    [ -n "$HANDOFF_GOALS" ] && echo "$HANDOFF_GOALS"
    [ -n "$HANDOFF_IP" ] && echo "$HANDOFF_IP"
    [ -n "$HANDOFF_BLOCKERS" ] && echo "$HANDOFF_BLOCKERS"
  fi

  cat << 'MAINTAIN'

After processing the pending reflection, spawn the knowledge-maintainer agent (subagent_type: "second-brain:knowledge-maintainer") to curate ~/knowledge/wiki/. It should: merge duplicate entries, update index.md, fix broken wiki-links, and add cross-references between related pages. Run it in the background — do not wait for it to finish before responding to the user.
MAINTAIN

  # Check if plugin self-improvement was suggested AND enabled in config
  SUGGEST=$(jq -r '.suggest_plugin_improve // false' "$HOME/.second-brain/.pending-reflection.json" 2>/dev/null)
  AUTO_IMPROVE=$(jq -r '.auto_improve // false' "$HOME/.second-brain/config.json" 2>/dev/null)
  if [ "$SUGGEST" = "true" ] && [ "$AUTO_IMPROVE" = "true" ]; then
    cat << IMPROVE

PLUGIN SELF-IMPROVEMENT TRIGGERED — After processing the reflection and responding to the user, spawn a background subagent (subagent_type: "general-purpose") and follow the protocol in:

  $PLUGIN_ROOT/scripts/improve-protocol.md

Read that file first, then execute its steps. Set PLUGIN_ROOT="$PLUGIN_ROOT" in your shell context.
IMPROVE
  fi
fi
