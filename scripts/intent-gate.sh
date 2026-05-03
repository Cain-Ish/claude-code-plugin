#!/bin/bash
# UserPromptSubmit hook. Re-injects the Intent Analysis protocol from USER.md
# as additionalContext for substantive user prompts so it stays sticky once
# scrollback buries the SessionStart hot tier.
#
# Contract: stdin is the UserPromptSubmit JSON payload; stdout is either
# empty (trivial prompt, ignored) or a JSON envelope with
# hookSpecificOutput.additionalContext. Always exits 0 — this hook must
# never block a user prompt; failures fall back to silent no-op.
#
# Substantive vs trivial classification:
#   - trivial: empty, ack words ("yes", "ok", "no", "go", "done", "lgtm",
#     "ship it", "thanks, ..."), or any prompt of <7 words that is not
#     introduced by an action verb.
#   - substantive: >=7 words, OR starts with a known action verb
#     (implement|build|add|fix|refactor|design|create|write|plan|debug|
#      investigate|update|migrate|integrate|review|...).
#
# The fail-soft contract is intentional: a Stop/PostToolUse hook that
# crashes is recoverable. A UserPromptSubmit hook that crashes blocks every
# user message in the session — far worse UX than missing an Intent
# reminder.
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

# Sentence-shaped ack ("thanks, that worked", "perfect, ship it", ...) —
# strip prefix, treat as ack only if the whole sentence is short feedback.
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

read -r -d '' CONTEXT <<'EOF' || true
[Intent Analysis — run before answering]

Per USER.md ## Intent: this looks like a substantive request. Before coding:

1. Extract the 3-5 keywords from the request (domain, action, surface).
2. Run the `second-brain:query` skill on those keywords. Read top 1-2 hits
   in full. Look for prior decisions, design plans, conventions, blockers,
   and restrictions the user has not restated.
3. Generate the followups a senior colleague would ask: "is there an
   existing implementation? what tech stack and version? does anything
   similar already exist? what scope/auth/pagination is implied? what
   does 'all' actually mean here?" — adapt to this specific request.
4. Answer the followups yourself from retrieved context where possible.
   Surface only the ones that remain genuinely ambiguous AND costly to
   guess wrong, as one focused clarifying question.
5. If the wiki had nothing relevant, say so explicitly so the user knows
   you checked. Then proceed with your best interpretation.

Skip steps 1-4 only if this is a trivial one-verb-on-one-noun edit.
EOF

jq -nc --arg ctx "$CONTEXT" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}' 2>/dev/null || exit 0
exit 0
