#!/bin/bash
# UserPromptSubmit hook. Extracts keywords from substantive prompts, runs
# BM25 search against the wiki, and injects top results as additionalContext
# so Claude gets relevant knowledge without a separate MCP tool call.
#
# Contract: stdin is the UserPromptSubmit JSON payload; stdout is either
# empty (trivial prompt) or a JSON envelope with additionalContext.
# Always exits 0 — must never block a user prompt.
set -u

RAW=$(cat 2>/dev/null || true)
if [ -z "$RAW" ]; then exit 0; fi

PROMPT=$(printf '%s' "$RAW" | jq -r '.prompt // empty' 2>/dev/null || true)
if [ -z "$PROMPT" ]; then exit 0; fi

P_LOWER=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')
P_TRIM="${P_LOWER# }"; P_TRIM="${P_TRIM% }"

W_COUNT=$(printf '%s' "$P_TRIM" | wc -w | tr -d ' ')

# Exact-match acks.
case "$P_TRIM" in
  yes|y|ok|okay|k|kk|sure|no|n|nope|done|good|great|nice|cool|right|correct|\
go|"go ahead"|"go for it"|"do it"|"let's go"|continue|next|proceed|\
lgtm|"ship it"|merge|approved|"sounds good"|"works for me"|wfm|fine|\
thanks|thx|ty|"thank you")
    exit 0 ;;
esac

# Sentence-shaped ack ("thanks, that worked", "perfect, ship it", ...)
case "$P_TRIM" in
  thanks*|thx*|"thank you"*|"thats "*|"that's "*|"that "*|perfect*|"works."*|"works,"*)
    if [ "$W_COUNT" -le 8 ]; then exit 0; fi ;;
esac

# Action-verb fast path — short prompts with a leading action verb count as
# substantive even under the 7-word threshold.
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

# --- Build search query from prompt keywords ---
STOP_WORDS="the a an is are was were will be been have has had do does did can could should would may might must shall to of in for on at by with from as into about between through after before during without under over up down out off then than so if or and but not no all each every both few more most other some any many much own same that this those these what which who whom whose when where how why it its i me my we our us you your he him his she her they them their also just only very really already still even well too"

KEYWORDS=$(printf '%s' "$P_TRIM" | tr -cs '[:alpha:]' '\n' | grep -vwF "$(echo "$STOP_WORDS" | tr ' ' '\n')" | head -8 | tr '\n' ' ')
KEYWORDS="${KEYWORDS% }"

if [ -z "$KEYWORDS" ]; then exit 0; fi

# --- Search wiki via bundled BM25 engine ---
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SEARCH_CLI="$PLUGIN_ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
WIKI_CAP=800    # ~200 tokens per injection — compact titles only, details on demand

WIKI_HITS=""
if [ -f "$SEARCH_CLI" ]; then
  WIKI_HITS=$(KNOWLEDGE_DIR="$KD" node "$SEARCH_CLI" "$KEYWORDS" 2>/dev/null || true)
fi

if [ ${#WIKI_HITS} -gt "$WIKI_CAP" ]; then
  WIKI_HITS=$(printf '%s' "$WIKI_HITS" | head -c "$WIKI_CAP")
fi

# --- Episodic memory search ---
EPISODIC_CLI="$PLUGIN_ROOT/mcp/dist/tools/episodic-index-cli.bundle.js"
EPISODIC_HINT=""
if [ -f "$PLUGIN_ROOT/mcp/dist/tools/episodic-search-cli.bundle.js" ]; then
  EPISODIC_HINT=$(BRAIN_DIR="$HOME/.second-brain" node "$PLUGIN_ROOT/mcp/dist/tools/episodic-search-cli.bundle.js" "$KEYWORDS" 2>/dev/null || true)
fi

# --- Compose context ---
if [ -z "$WIKI_HITS" ] && [ -z "$EPISODIC_HINT" ]; then
  exit 0
fi

CONTEXT=""
if [ -n "$WIKI_HITS" ]; then
  CONTEXT="[Knowledge context — auto-retrieved from wiki, do not re-query these pages]

$WIKI_HITS"
fi

if [ -n "$EPISODIC_HINT" ]; then
  CONTEXT="$CONTEXT
$EPISODIC_HINT"
fi

CONTEXT="$CONTEXT
---
If the above knowledge is relevant, use it directly. Only call knowledge_search if you need additional pages not shown here."

jq -nc --arg ctx "$CONTEXT" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}' 2>/dev/null || exit 0
exit 0
