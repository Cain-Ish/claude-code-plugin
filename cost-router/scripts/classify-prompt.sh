#!/bin/bash
# cost-router/scripts/classify-prompt.sh
# UserPromptSubmit hook: classify the incoming prompt into a cost-router tier
# and inject a one-line advisory nudge into context.
#
# Kill switch: COST_ROUTER_AUTOROUTE=off → exit 0 with no output.
# Never exits nonzero / never breaks the prompt. Best-effort log only.
#
# Tier priority (checked in order):
#   THINK (Opus):  design, architect, architecture, plan, strategy, trade-off/tradeoff,
#                  approach, "how should", ambiguous, refactor, security
#   SCOUT (Haiku): read, show, find, search, grep, list, "what is", "where is",
#                  explain, summarize, run tests, lint, typecheck
#   DO (Sonnet):   DEFAULT — implement, add, fix, write, edit, change, create, update
#
# Output: JSON {hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:"..."}}
#   (matches persona-context.sh output convention for UserPromptSubmit hooks).
#
# Bash 3.2 / BSD-safe: no mapfile, no declare -A, no grep -P, no date -d.

set -u

# Kill switch
[ "${COST_ROUTER_AUTOROUTE:-on}" = "off" ] && exit 0

RAW=$(cat 2>/dev/null || true)
[ -z "$RAW" ] && exit 0

PROMPT=$(printf '%s' "$RAW" | jq -r '.prompt // empty' 2>/dev/null || true)
[ -z "$PROMPT" ] && exit 0

# Lowercase for case-insensitive matching. Bash 3.2: use tr not ${x,,}.
P_LOWER=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')

# ── Classify ──────────────────────────────────────────────────────────────────

TIER=""

# THINK: check first (highest priority)
case "$P_LOWER" in
  *design*|*architect*|*architecture*|*plan*|*strategy*|*"trade-off"*|*tradeoff*|\
  *approach*|*"how should"*|*ambiguous*|*refactor*|*security*)
    TIER="THINK" ;;
esac

# SCOUT: check second if not already THINK
if [ -z "$TIER" ]; then
  case "$P_LOWER" in
    *"read "*|*"show "*|*"find "*|*"search "*|*grep*|*"list "*|\
    *"what is"*|*"where is"*|*explain*|*summarize*|\
    *"run test"*|*lint*|*typecheck*)
      TIER="SCOUT" ;;
  esac
fi

# DO: default
if [ -z "$TIER" ]; then
  TIER="DO"
fi

# ── Map tier to model name ─────────────────────────────────────────────────────

case "$TIER" in
  THINK) MODEL="Opus" ;;
  SCOUT) MODEL="Haiku" ;;
  *)     MODEL="Sonnet" ;;
esac

# ── Emit nudge as additionalContext ───────────────────────────────────────────

NUDGE="cost-router: this looks like ${TIER} → ${MODEL}. For full tiering run /cost-router:orchestrate."

jq -nc --arg ctx "$NUDGE" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}' 2>/dev/null || exit 0

# ── Best-effort classification log ────────────────────────────────────────────

# Build a short prompt slug: first 40 chars, spaces→underscores, strip non-alnum/underscore/hyphen.
SLUG=$(printf '%s' "$P_LOWER" | head -c 40 | tr ' ' '_' | tr -cd 'a-zA-Z0-9_-')
ROUTE_LOG="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/scripts/route-log.sh"
bash "$ROUTE_LOG" emit "$SLUG" "$TIER" "" "0" "false" "classified" "false" 2>/dev/null || true

exit 0
