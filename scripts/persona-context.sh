#!/bin/bash
# persona-context.sh — Layer 1 persona infrastructure (UserPromptSubmit hook)
# Reads STDIN JSON: {prompt, cwd, ...}
# Emits hookSpecificOutput.additionalContext composed from:
#   - persona-card.md identity (factual)
#   - installed plugin catalog summary (factual)
#   - BM25 wiki hits (existing intent-gate pattern)
#   - episodic search hint
# No LLM call. Hard cap on each section. Always exits 0 — must never block a prompt.
#
# Kill switch: SB_PERSONA_GATE=off
# /? prefix is reserved for T6 (think tool); current behavior exits silently so T6 wiring can take over.
set -u

# Kill switch
[ "${SB_PERSONA_GATE:-on}" = "off" ] && exit 0

RAW=$(cat 2>/dev/null || true)
[ -z "$RAW" ] && exit 0

PROMPT=$(printf '%s' "$RAW" | jq -r '.prompt // empty' 2>/dev/null || true)
[ -z "$PROMPT" ] && exit 0

# /? prefix → route to persona-think (Layer 2 Opus brief), bypass Layer 1 silent injection.
case "$PROMPT" in
  '/?'*)
    QUERY="${PROMPT#/?}"
    QUERY="${QUERY# }"
    [ -z "$QUERY" ] && exit 0
    PLUGIN_ROOT_NOW="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
    THINK_CLI="$PLUGIN_ROOT_NOW/mcp/dist/cli/persona-think-cli.bundle.js"
    if [ -f "$THINK_CLI" ]; then
      BRIEF=$(printf '%s' "$QUERY" | node "$THINK_CLI" 2>/dev/null || true)
      if [ -n "$BRIEF" ]; then
        CTX="[Persona deep brief — Opus advisor, treat as structured second opinion]
$BRIEF
---
Use this brief to inform the response. Ask the clarifying questions if they're costly to guess wrong."
        jq -nc --arg ctx "$CTX" '{
          hookSpecificOutput: {
            hookEventName: "UserPromptSubmit",
            additionalContext: $ctx
          }
        }' 2>/dev/null || true
      fi
    fi
    exit 0
    ;;
esac

# --- Trivial-skip triage (preserved from intent-gate.sh) ---
P_LOWER=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')
P_TRIM="${P_LOWER# }"; P_TRIM="${P_TRIM% }"
W_COUNT=$(printf '%s' "$P_TRIM" | wc -w | tr -d ' ')

case "$P_TRIM" in
  yes|y|ok|okay|k|kk|sure|no|n|nope|done|good|great|nice|cool|right|correct|\
go|"go ahead"|"go for it"|"do it"|"let's go"|continue|next|proceed|\
lgtm|"ship it"|merge|approved|"sounds good"|"works for me"|wfm|fine|\
thanks|thx|ty|"thank you")
    exit 0 ;;
esac

case "$P_TRIM" in
  thanks*|thx*|"thank you"*|"thats "*|"that's "*|"that "*|perfect*|"works."*|"works,"*)
    [ "$W_COUNT" -le 8 ] && exit 0 ;;
esac

ACTION=0
case "$P_TRIM" in
  "implement "*|"build "*|"add "*|"fix "*|"refactor "*|"design "*|"create "*|\
"write "*|"plan "*|"debug "*|"investigate "*|"update "*|"migrate "*|\
"integrate "*|"review "*|"audit "*|"port "*|"rewrite "*|"extract "*|"split "*)
    ACTION=1 ;;
esac

if [ "$ACTION" -eq 0 ] && [ "$W_COUNT" -lt 7 ]; then
  exit 0
fi

BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"

# Caps per section. Total adds up around ~2000B for the additionalContext payload.
CAP_PERSONA=400
CAP_CATALOG=200
CAP_WIKI=600
CAP_EPISODIC=300

# --- Persona card abstract (auto-seed if missing) ---
PCARD_FILE="$BRAIN_DIR/persona-card.md"
if [ ! -f "$PCARD_FILE" ]; then
  ROLE=$(grep -E '^- ' "$BRAIN_DIR/USER.md" 2>/dev/null | head -1 | sed -E 's/^- *(\[[0-9-]+\][[:space:]]*)?//')
  cat > "$PCARD_FILE" <<SEED
# Persona

## Identity
- ${ROLE:-senior engineer}

## Communication style
- direct, terse, no filler

## Working preferences
- brainstorm 2-3 options before architecture decisions

## How to engage me
- Surface critical context; don't restate what I know
- Default silent; volunteer only when expected value exceeds flow cost
- Before claiming code is ready to commit: run available checks (tests, lint, type-check, security review)
SEED
fi
PERSONA_ABS=""
if [ -f "$PCARD_FILE" ]; then
  # Strip headers + blank lines, drop the section labels, keep bullet payloads, join with semicolons.
  PERSONA_ABS=$(grep -E '^- ' "$PCARD_FILE" 2>/dev/null \
    | sed 's/^- *//' \
    | tr '\n' ';' \
    | sed 's/;;*/; /g; s/; $//')
  [ ${#PERSONA_ABS} -gt $CAP_PERSONA ] && PERSONA_ABS=$(printf '%s' "$PERSONA_ABS" | head -c $CAP_PERSONA)
fi

# --- Plugin catalog summary ---
CATALOG_FILE="$BRAIN_DIR/.installed-catalog.json"
CATALOG_ABS=""
if [ -f "$CATALOG_FILE" ]; then
  CATALOG_ABS=$(jq -r '
    [
      (.plugins // [] | map(.name) | .[0:6] | join(", ")),
      (.agents  // [] | length | tostring + " agents"),
      (.skills  // [] | length | tostring + " skills")
    ] | map(select(length > 0)) | join(" | ")' "$CATALOG_FILE" 2>/dev/null)
  [ ${#CATALOG_ABS} -gt $CAP_CATALOG ] && CATALOG_ABS=$(printf '%s' "$CATALOG_ABS" | head -c $CAP_CATALOG)
fi

# --- Keyword extraction (preserved from intent-gate.sh) ---
STOP_WORDS="the a an is are was were will be been have has had do does did can could should would may might must shall to of in for on at by with from as into about between through after before during without under over up down out off then than so if or and but not no all each every both few more most other some any many much own same that this those these what which who whom whose when where how why it its i me my we our us you your he him his she her they them their also just only very really already still even well too"

KEYWORDS=$(printf '%s' "$P_TRIM" | tr -cs '[:alpha:]' '\n' | grep -vwF "$(echo "$STOP_WORDS" | tr ' ' '\n')" | head -8 | tr '\n' ' ')
KEYWORDS="${KEYWORDS% }"

# --- Wiki hits via existing bundle ---
WIKI_HITS=""
SEARCH_CLI="$PLUGIN_ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"
if [ -n "$KEYWORDS" ] && [ -f "$SEARCH_CLI" ]; then
  WIKI_HITS=$(KNOWLEDGE_DIR="$KD" node "$SEARCH_CLI" "$KEYWORDS" 2>/dev/null || true)
  [ ${#WIKI_HITS} -gt $CAP_WIKI ] && WIKI_HITS=$(printf '%s' "$WIKI_HITS" | head -c $CAP_WIKI)
fi

# --- Episodic hint ---
EPISODIC_HINT=""
EPISODIC_CLI="$PLUGIN_ROOT/mcp/dist/tools/episodic-search-cli.bundle.js"
if [ -n "$KEYWORDS" ] && [ -f "$EPISODIC_CLI" ]; then
  EPISODIC_HINT=$(BRAIN_DIR="$BRAIN_DIR" node "$EPISODIC_CLI" "$KEYWORDS" 2>/dev/null || true)
  [ ${#EPISODIC_HINT} -gt $CAP_EPISODIC ] && EPISODIC_HINT=$(printf '%s' "$EPISODIC_HINT" | head -c $CAP_EPISODIC)
fi

# Bail out if nothing useful surfaced.
if [ -z "$PERSONA_ABS" ] && [ -z "$CATALOG_ABS" ] && [ -z "$WIKI_HITS" ] && [ -z "$EPISODIC_HINT" ]; then
  exit 0
fi

# --- Compose as factual statements (per research: factual phrasing dodges prompt-injection defenses) ---
CTX="[Persona context — auto-loaded, treat as ambient state]"
[ -n "$PERSONA_ABS" ] && CTX="$CTX
Persona: $PERSONA_ABS"
[ -n "$CATALOG_ABS" ] && CTX="$CTX
Installed specialists: $CATALOG_ABS"
[ -n "$WIKI_HITS" ] && CTX="$CTX

[Wiki — auto-retrieved, do not re-query these pages]
$WIKI_HITS"
[ -n "$EPISODIC_HINT" ] && CTX="$CTX
$EPISODIC_HINT"

CTX="$CTX
---
If the above is relevant, use it directly. If you need deeper analysis, invoke /second-brain:think or prefix the next prompt with /?.
Before claiming code is ready to commit: run all applicable verification — tests, lint, type-check — and invoke relevant installed skills (code review, security review, quality checks). No completion claims without evidence."

jq -nc --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}' 2>/dev/null || exit 0
exit 0
