#!/bin/bash
# Session initialization instruction injected at SessionStart via stdout.
# Tells Claude to load persona, quality rules, learnings, and tools.

BRAIN_DIR="$HOME/.second-brain"

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
PLUGIN_ROOT_LOCAL="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LEARNINGS_FILE="$HOME/.second-brain/learnings.md"
LEARNINGS_HOT="$HOME/.second-brain/.learnings-hot.md"
if [ -f "$LEARNINGS_FILE" ] && [ -f "$PLUGIN_ROOT_LOCAL/scripts/budget-context.sh" ]; then
  bash "$PLUGIN_ROOT_LOCAL/scripts/budget-context.sh" > "$LEARNINGS_HOT" 2>/dev/null || cp "$LEARNINGS_FILE" "$LEARNINGS_HOT"
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
[ -f "$PLUGIN_ROOT_LOCAL/.claude-plugin/plugin.json" ] && CURRENT_VERSION=$(jq -r '.version // ""' "$PLUGIN_ROOT_LOCAL/.claude-plugin/plugin.json" 2>/dev/null)
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
    RECENT_DRIFT=$(jq -s --arg c "$CUTOFF_7D" '[.[] | select(.timestamp >= $c)] | length' "$DRIFT_LOG" 2>/dev/null)
    RECENT_DRIFT=${RECENT_DRIFT:-0}
    if [ "$RECENT_DRIFT" -ge 5 ]; then
      DRIFT_NUDGE="

PERSONA DRIFT DETECTED — $RECENT_DRIFT signal hits in the last 7 days against ~/.second-brain/persona.md rules. Run /second-brain:drift-check for the breakdown."
    fi
  fi
fi

cat << EOF
SECOND BRAIN LOAD - Read these files now and internalize for the entire session:
- ~/.second-brain/persona.md (behavioral rules, code style, intent analysis)
- ~/.second-brain/quality-rules.md (code quality standards - applied on every write)
- $LEARNINGS_LINE$TOOLS_LINE$VERSION_NUDGE$GRAPH_NUDGE$DRIFT_NUDGE

CONTEXT-RELEVANT NODE LOADING (Karpathy second-brain pattern): when the user's request touches a topic the wiki likely covers — a tool/library/framework name, a person, an organization, a project, a domain concept — proactively call the knowledge_search MCP tool with the key terms BEFORE answering. Read any result with relevance > 0.6 in full and incorporate it. This applies to substantive technical questions, design discussions, anything where prior context would change the answer. Do not ask the user "should I search?" — just do it. For trivial requests (rename, fix a typo, run a command), skip the search.

If ~/.second-brain/.pending-reflection.json exists, process silently using BOTH sources:

(1) FRICTION-BASED: read friction-log.jsonl for process learnings (retries, rejections, fix requests).

(2) CONTENT-BASED: if the pending reflection contains a transcript_path and the file exists on disk, read the last 200 lines of assistant turns from it (use Read tool with offset, or jq to filter .type=="assistant" entries). Look for substantive knowledge that should survive session boundaries:
- Architecture decisions and their rationale
- Component/file structure changes or migration plans
- Design patterns adopted or rejected
- Technical debt identified or addressed
- Key decisions with reasoning
- Tool/library evaluations and conclusions
This applies even when friction_count is 0 — smooth productive sessions often contain the richest knowledge.

From BOTH sources combined, extract 1-3 candidate learnings. Then BEFORE writing anything, run an asymmetric critic gate to prevent same-context judge-and-author bias (Iterative Self-Refinement Reward Hacking). For each candidate, dispatch a fresh-context subagent (subagent_type: "second-brain:quality-reviewer" for code, "general-purpose" otherwise) with ONLY the proposal text + destination file + one anonymized friction example + the current destination contents — no transcript. Ask it to score (specific? generalizes? conflicts with existing? would removal cause friction to recur?) and return ACCEPT/REVISE/REJECT. Only write ACCEPTed proposals (apply REVISE suggestions before writing); drop REJECTs silently. Log every verdict to ~/.second-brain/critic-log.jsonl as {timestamp, session_id, proposal_title, destination, verdict, reason}. Then update learnings.md/quality-rules.md/persona.md as needed (in learnings.md, every new entry MUST include a meta line right under the header: "<!-- meta: confidence=0.X hits=0 last_used=YYYY-MM-DD -->" using the critic's confidence score — scripts/decay-learnings.sh parses these to evict stale low-confidence entries), create ~/knowledge/wiki/sessions/YYYY-MM-DD-topic.md, mirror each new learning as a wiki node under ~/knowledge/wiki/learnings/YYYY-MM-DD-short-title.md (with [[wiki-link]] cross-references to the entities/concepts it touches and a back-link to the session page), update ~/knowledge/index.md and ~/knowledge/log.md (the root files — never create these inside wiki/), delete the pending-reflection file.

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

  if [ -n "$PENDING_TRANSCRIPT" ] && [ -f "$PENDING_TRANSCRIPT" ]; then
    cat << CONTENT

CONTENT-BASED SESSION REVIEW — The session transcript is available at: $PENDING_TRANSCRIPT (trigger: $PENDING_TRIGGER, friction: $PENDING_FRICTION, user_turns: $PENDING_TURNS).

Read the last 200 lines of this transcript using the Read tool (calculate offset from file length). Focus on assistant turns with substantive content — skip tool-call-only turns. Extract knowledge worth preserving:
- Architecture decisions and rationale
- Component/file structure changes, migrations, refactors
- Design patterns adopted or rejected
- Technical debt identified or addressed
- Key decisions with reasoning that would help future sessions
- Project context that isn't derivable from code alone

Create wiki session and entity pages for significant findings. This is especially important for productive sessions with zero friction — those often contain the richest knowledge that would otherwise be lost.
CONTENT
  fi

  cat << 'MAINTAIN'

After processing the pending reflection, spawn the knowledge-maintainer agent (subagent_type: "second-brain:knowledge-maintainer") to curate ~/knowledge/wiki/. It should: merge duplicate entries, update index.md, fix broken wiki-links, and add cross-references between related pages. Run it in the background — do not wait for it to finish before responding to the user.
MAINTAIN

  # Check if plugin self-improvement was suggested AND enabled in config
  SUGGEST=$(jq -r '.suggest_plugin_improve // false' "$HOME/.second-brain/.pending-reflection.json" 2>/dev/null)
  AUTO_IMPROVE=$(jq -r '.auto_improve // false' "$HOME/.second-brain/config.json" 2>/dev/null)
  if [ "$SUGGEST" = "true" ] && [ "$AUTO_IMPROVE" = "true" ]; then
    PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
    cat << IMPROVE

PLUGIN SELF-IMPROVEMENT TRIGGERED — After processing the reflection and responding to the user, spawn a background subagent (subagent_type: "general-purpose") and follow the protocol in:

  $PLUGIN_ROOT/scripts/improve-protocol.md

Read that file first, then execute its steps. Set PLUGIN_ROOT="$PLUGIN_ROOT" in your shell context.
IMPROVE
  fi
fi
