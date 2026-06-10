#!/bin/bash
# cost-router/scripts/classify-prompt.sh
# UserPromptSubmit hook: classify the incoming prompt into a cost-router tier
# and inject a one-line advisory nudge into context.
#
# Kill switch: COST_ROUTER_AUTOROUTE=off → exit 0 with no output.
# Never exits nonzero / never breaks the prompt. Best-effort log only.
#
# Tier priority (checked in order; R5.1 word-bounded on a punctuation-normalized
# padded copy — see CR-006 in the deep-dive findings):
#   THINK (Opus):  design/redesign, architect(ure), plan/plans/planning (words),
#                  strategy, trade-off/tradeoff, approach (word), "how should", ambiguous
#   SCOUT (Haiku): read, show, find, search, grep, list, "what is", "where is",
#                  explain, summarize, run tests, lint, typecheck
#   DO (Sonnet):   DEFAULT — implement, add, fix, write, edit, change, create, update
#
# Every prompt logs a route-log event. A nudge is INJECTED only for THINK/SCOUT
# on prompts >= 25 chars: DO is the default (advising the default is noise) and
# trivial prompts need no routing advice.
#
# Output (when nudging): JSON {hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:"..."}}
#   (matches persona-context.sh output convention for UserPromptSubmit hooks).
#
# Bash 3.2 / BSD-safe: no mapfile, no declare -A, no grep -P, no date -d.

set -u
# Nested-spawn circuit breaker (R1.1/R5.1): inside a plugin-spawned headless session, context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0

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

# THINK: check first (highest priority). R5.1 (CR-006): word-bounded matches on
# a space-padded copy — bare substrings fired on e.g. "docs/plans/foo.md"
# (*plan*) and "the security module" (*security*), nudging toward the EXPENSIVE
# model on routine prompts. `refactor` and `security` are dropped entirely.
# Punctuation → spaces before padding, so "plan:" / "plan," still word-match
# (deep-review: trailing punctuation defeated the space-bounded tokens).
P_PAD=" $(printf '%s' "$P_LOWER" | tr ',:;.!?' ' ') "
case "$P_PAD" in
  *" design"*|*" redesign"*|*" architect"*|*" plan "*|*" plans "*|*" planning "*|*" strategy"*|\
  *" trade-off"*|*" tradeoff"*|*" approach "*|*"how should"*|*" ambiguous"*)
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

# ── Best-effort classification log (ALWAYS — silence is not data loss) ────────

# Build a short prompt slug: first 40 chars, spaces→underscores, strip non-alnum/underscore/hyphen.
SLUG=$(printf '%s' "$P_LOWER" | head -c 40 | tr ' ' '_' | tr -cd 'a-zA-Z0-9_-')
ROUTE_LOG="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/scripts/route-log.sh"
bash "$ROUTE_LOG" emit "$SLUG" "$TIER" "" "0" "false" "classified" "false" 2>/dev/null || true

# ── Emit nudge as additionalContext ───────────────────────────────────────────
# R5.1 (CR-006): nudge ONLY when it carries information — DO is the default
# (advising the default is per-prompt noise), and trivial prompts ("continue",
# "yes") need no routing advice.
[ "$TIER" = "DO" ] && exit 0
[ "${#PROMPT}" -lt 25 ] && exit 0

NUDGE="cost-router: this looks like ${TIER} → ${MODEL}. For full tiering run /cost-router:orchestrate."

jq -nc --arg ctx "$NUDGE" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}' 2>/dev/null || exit 0

exit 0
