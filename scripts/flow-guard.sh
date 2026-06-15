#!/bin/bash
# flow-guard.sh — v2.10.0 PreToolUse hook (HarnessAudit sar_flow channel).
#
# Asks before a tool call that combines an OUTBOUND egress channel with a
# CREDENTIAL-shaped payload in the tool input. Closes the third L1 boundary
# (alongside tool-scope and resource-scope). The most realistic exfil mode
# in an LLM-driven workflow is the agent helpfully pasting a session secret
# into an http request — the paper calls this a "flow boundary" violation.
#
# In scope:
#   - Bash: command must contain a network tool AND a credential pattern.
#   - WebFetch / WebSearch: any credential pattern anywhere in tool_input.
#
# Out of scope (other guards / non-egress):
#   - Edit / Write / Read — local file ops, handled by resource-scope.
#   - Task — subagent dispatch is a separate channel (future work).
#
# Patterns detected (conservative; false-negative leaning):
#   JWT, AWS Access Key, GitHub PAT (legacy + fine-grained), Anthropic
#   key, OpenAI key, Slack token, PEM private key block, Bearer + long
#   base64 (≥40 chars) bundle. All anchored with surrounding context to
#   avoid tripping on test fixtures of random base64.
#
# Verdict: ask. Reason carries which pattern matched (no secret value).
# Logged to audit-log.jsonl. Kill switch: SB_FLOW_GUARD=off.
# Always exits 0.
set -u

[ "${SB_FLOW_GUARD:-on}" = "off" ] && exit 0

RAW=$(cat 2>/dev/null || true)
[ -z "$RAW" ] && exit 0
echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$RAW" | jq -r '.tool_name // empty' 2>/dev/null | tr -d '\r')
[ -z "$TOOL" ] && exit 0

# Only outbound channels concern us.
case "$TOOL" in
  Bash|WebFetch|WebSearch) ;;
  *) exit 0 ;;
esac

SESSION_ID=$(printf '%s' "$RAW" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r')
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Fail-soft on lib.sh source so the guard still emits its decision JSON
# even if audit logging is unavailable.
if ! source "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null; then
  sb_log_audit() { :; }
fi

# Pull the haystack — tool-specific payload.
case "$TOOL" in
  Bash)
    HAYSTACK=$(printf '%s' "$RAW" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')
    ;;
  WebFetch)
    HAYSTACK=$(printf '%s' "$RAW" \
      | jq -r '[.tool_input.url // "", .tool_input.prompt // ""] | join(" ")' 2>/dev/null)
    ;;
  WebSearch)
    HAYSTACK=$(printf '%s' "$RAW" | jq -r '.tool_input.query // empty' 2>/dev/null | tr -d '\r')
    ;;
esac
[ -z "$HAYSTACK" ] && exit 0

# Bash gate: require a network tool keyword in addition to the credential
# pattern. Without this, a local `echo $TOKEN > file` would be flagged —
# noise without exfil risk.
# Note: `http` is intentionally NOT in the keyword list — it appears as
# a URL substring in many local commands (grep over access.log, paths
# containing http-* names) and would trip the egress gate on grep/awk/sed
# operations that never touch the network. httpie has the binary name
# `http` but the keyword match is bounded — keeping only `httpie` is the
# conservative choice (the few power-users running httpie can disable the
# guard or use curl).
if [ "$TOOL" = "Bash" ]; then
  if ! printf '%s' "$HAYSTACK" \
    | grep -qE '(^|[^A-Za-z_])(curl|wget|nc|netcat|ssh|scp|sftp|rsync|httpie|ftp)([^A-Za-z_]|$)'; then
    exit 0
  fi
fi

# Pattern set. Each line: label|extended-regex. Order doesn't matter; we
# collect all matches and report the labels. Keep the per-pattern egrep
# narrow so we don't accidentally match readable English text.
MATCHED_LABELS=""

scan() {
  local label="$1" pattern="$2"
  if printf '%s' "$HAYSTACK" | grep -qE "$pattern"; then
    if [ -z "$MATCHED_LABELS" ]; then
      MATCHED_LABELS="$label"
    else
      MATCHED_LABELS="$MATCHED_LABELS,$label"
    fi
  fi
}

scan "jwt"            'ey[A-Za-z0-9_-]{10,}\.ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
scan "aws-access-key" 'AKIA[0-9A-Z]{16}'
scan "github-pat"     '(ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,})'
scan "anthropic-key"  'sk-ant-(api|admin)[0-9]*-[A-Za-z0-9_-]{20,}'
# OpenAI: matches both legacy keys (`sk-` + 40+ base62) and the current
# project-scoped format (`sk-proj-` + body). Hyphens allowed inside the
# body to accommodate `sk-proj-...`. Anthropic and Slack tokens are
# matched by their dedicated patterns earlier — duplicate matches just
# add labels, they don't break anything.
scan "openai-key"     'sk-(proj-[A-Za-z0-9_-]{20,}|[A-Za-z0-9]{40,})'
scan "slack-token"    'xox[abprs]-[A-Za-z0-9-]{10,}'
scan "pem-private"    'BEGIN[[:space:]]+(RSA|EC|DSA|OPENSSH|PGP|ENCRYPTED)?[[:space:]]*PRIVATE[[:space:]]+KEY'
scan "bearer-blob"    '[Bb]earer[[:space:]]+[A-Za-z0-9+/=_-]{40,}'

[ -z "$MATCHED_LABELS" ] && exit 0

# Decision: ask. The audit-log TARGET intentionally carries only the
# matched labels — NOT the haystack content — because the haystack
# contains the secret value we just detected. v2.10.0 review (B2): the
# old "${HAYSTACK:0:80}" sliced enough of e.g. a JWT prefix into the
# log to be re-recognized by downstream consumers. Labels alone give
# /second-brain:audit and the SAR summary everything they need.
TARGET="${TOOL}:(${MATCHED_LABELS})"
REASON="Outbound info-flow guard: tool '$TOOL' invocation appears to carry credential-shaped content (${MATCHED_LABELS}). HarnessAudit treats credentialed egress as the sar_flow boundary-violation channel. Confirm intent — the agent should not be sending real secrets over the wire. Kill switch: SB_FLOW_GUARD=off."

sb_log_audit "flow-guard.sh" "ask" "info-flow:${MATCHED_LABELS}" "$TARGET" "$REASON" "$SESSION_ID"

jq -nc --arg r "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: $r
  }
}' 2>/dev/null || true

exit 0
