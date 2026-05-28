#!/bin/bash
# symlink-guard.sh — PreToolUse hook for Write/Edit/MultiEdit.
#
# Closes G-HOOK-2 (wiki/security/plugin-hardening-gap-analysis-2026-05-28.md).
# Blocks writes whose path (after symlink resolution) lands inside a known
# credential-bearing directory. Defense against the symlink-escape exfil
# scenario where Claude is instructed to write a benign-looking file that is
# actually a symlink into ~/.ssh, ~/.gnupg, etc.
#
# Anthropic doctrine: "Symlink resolution has to happen before path validation,
# not after." (engineering/how-we-contain-claude). We realpath first, then
# match the *resolved* path against the credential-dir list.
#
# In scope:
#   - Write / Edit / MultiEdit — any tool that mutates a file.
#
# Out of scope:
#   - Bash — uses flow-guard for credential-shaped egress.
#   - Read — read-only; not a write-escape risk.
#
# Credential-dir prefixes (after realpath, case-sensitive):
#   $HOME/.ssh, $HOME/.gnupg, $HOME/.aws, $HOME/.config/claude,
#   $HOME/.config/gh, $HOME/.netrc (file), /etc, $HOME/.password-store.
#
# Verdict: deny. Reason carries which credential dir matched (no content
# leaked).
#
# Kill switch: SB_SYMLINK_GUARD=off
# Always exits 0; decision flows through hookSpecificOutput JSON.
set -u

[ "${SB_SYMLINK_GUARD:-on}" = "off" ] && exit 0

RAW=$(cat 2>/dev/null || true)
[ -z "$RAW" ] && exit 0
printf '%s' "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$RAW" | jq -r '.tool_name // empty' 2>/dev/null)
case "$TOOL" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$RAW" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

# Tilde expansion. tool_input.file_path is usually absolute already; tilde-
# prefixed paths arrive verbatim and need expansion before realpath.
case "$FILE_PATH" in
  '~'*) FILE_PATH="$HOME${FILE_PATH#\~}" ;;
esac

# Resolve through symlinks. -m: missing-component-tolerant (Write targets the
# file may not exist yet); we still resolve the parent's symlinks.
RESOLVED=$(realpath -m -- "$FILE_PATH" 2>/dev/null)
[ -z "$RESOLVED" ] && exit 0  # realpath unavailable on this system → fail open

# Source lib.sh for sb_log_audit. Fail-soft.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
if ! source "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null; then
  sb_log_audit() { :; }
fi

SESSION_ID=$(printf '%s' "$RAW" | jq -r '.session_id // empty' 2>/dev/null || true)

# Credential-dir prefix check. Each entry is "label:absolute-prefix".
# Order matters only for which label the user sees first; the deny verdict
# is identical.
CRED_PREFIXES=(
  "ssh:$HOME/.ssh/"
  "gnupg:$HOME/.gnupg/"
  "aws:$HOME/.aws/"
  "claude-config:$HOME/.config/claude/"
  "gh-config:$HOME/.config/gh/"
  "passwordstore:$HOME/.password-store/"
  "etc:/etc/"
)
# Special case: $HOME/.netrc is a single file, not a prefix tree.
NETRC_FILE="$HOME/.netrc"

MATCHED_LABEL=""
for entry in "${CRED_PREFIXES[@]}"; do
  label="${entry%%:*}"
  prefix="${entry#*:}"
  case "$RESOLVED" in
    "$prefix"*) MATCHED_LABEL="$label"; break ;;
  esac
done
if [ -z "$MATCHED_LABEL" ] && [ "$RESOLVED" = "$NETRC_FILE" ]; then
  MATCHED_LABEL="netrc"
fi

[ -z "$MATCHED_LABEL" ] && exit 0

REASON="Write to '$FILE_PATH' resolves to '$RESOLVED' which is inside the credential directory '$MATCHED_LABEL'. Symlink-guard denies to prevent credential overwrite or exfil. Suppress: SB_SYMLINK_GUARD=off."
sb_log_audit "symlink-guard.sh" "deny" "credential-dir:$MATCHED_LABEL" "${TOOL}(${FILE_PATH})" "$REASON" "$SESSION_ID"

jq -nc --arg r "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}' 2>/dev/null || true
exit 0
