#!/bin/bash
# symlink-guard.sh — PreToolUse hook for Write/Edit/MultiEdit.
#
# Closes gap G-HOOK-2: symlinked wiki paths bypassed the write guard.
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

TOOL=$(printf '%s' "$RAW" | jq -r '.tool_name // empty' 2>/dev/null | tr -d '\r')
case "$TOOL" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$RAW" | jq -r '.tool_input.file_path // empty' 2>/dev/null | tr -d '\r')
[ -z "$FILE_PATH" ] && exit 0

# Tilde expansion. tool_input.file_path is usually absolute already; tilde-
# prefixed paths arrive verbatim and need expansion before realpath.
case "$FILE_PATH" in
  '~'*) FILE_PATH="$HOME${FILE_PATH#\~}" ;;
esac

# Source lib.sh for sb_log_audit + sb_normalize_path. Fail-soft: define no-op /
# minimal fallbacks so the guard still emits its deny JSON (its primary job)
# even if the source fails. sb_normalize_path MUST be available before the
# credential match below, so the guard stays armed on Windows even without lib.sh.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
if ! source "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null; then
  sb_log_audit() { :; }
  sb_normalize_path() {
    local p="${1//\\//}"
    p="${p#"//?/"}"   # \\?\C:\… extended-length prefix (minimal mirror of lib.sh's canonical)
    case "$p" in [A-Za-z]:/*) command -v cygpath >/dev/null 2>&1 && p=$(cygpath -u "$p" 2>/dev/null || printf '%s' "$p") ;; esac
    printf '%s' "$p"
  }
fi

# Windows git-bash sends 'C:\…' / 'C:/…'; normalize to the /c/… POSIX form the
# credential prefixes use BEFORE realpath (so it resolves) and again AFTER (GNU
# realpath re-emits C:/ form on Windows — normalizing its OUTPUT is the G-HOOK-2
# fix: without it the credential-dir prefixes never match and the guard is inert).
FILE_PATH=$(sb_normalize_path "$FILE_PATH")

# Resolve through symlinks. -m: missing-component-tolerant (Write targets the
# file may not exist yet); we still resolve the parent's symlinks.
RESOLVED=$(realpath -m -- "$FILE_PATH" 2>/dev/null)        # GNU coreutils: follows leaf + parent, missing-tolerant
[ -z "$RESOLVED" ] && RESOLVED=$(greadlink -f -- "$FILE_PATH" 2>/dev/null)  # macOS Homebrew coreutils
if [ -z "$RESOLVED" ]; then
  # Stock BSD/macOS (no GNU realpath/greadlink, or BSD realpath which lacks `-m`): resolve the
  # PARENT dir's symlinks PORTABLY via `cd … && pwd -P` (bash 3.2 / BSD safe), THEN dereference
  # the leaf itself if it is a symlink — so a benign-named file that is a symlink INTO a
  # credential dir is caught, not just a symlinked PARENT. Lexical ~-expansion is the last
  # resort. Fail CLOSED throughout — never a blind allow.
  _pd=$(dirname -- "$FILE_PATH"); _pb=$(basename -- "$FILE_PATH")
  _rpd=$(cd "$_pd" 2>/dev/null && pwd -P)
  if [ -n "$_rpd" ]; then
    if [ -L "$_rpd/$_pb" ]; then
      _tgt=$(readlink -- "$_rpd/$_pb" 2>/dev/null)
      case "$_tgt" in /*) RESOLVED="$_tgt" ;; *) RESOLVED="$_rpd/$_tgt" ;; esac
    else
      RESOLVED="$_rpd/$_pb"
    fi
  else
    RESOLVED="${FILE_PATH/#\~/$HOME}"
  fi
fi
# Normalize realpath's OUTPUT to the /c/… form so it matches the credential
# prefixes (see the pre-realpath note above — this is the load-bearing half).
RESOLVED=$(sb_normalize_path "$RESOLVED")

SESSION_ID=$(printf '%s' "$RAW" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r' || true)

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
# Case-INSENSITIVE compare: NTFS and default APFS are case-insensitive, so
# /c/Users/me/.SSH/ IS ~/.ssh there — a case-varied path must not slip the
# prefix check. On case-sensitive Linux this can over-match a literally
# distinct ~/.SSH dir; acceptable — a rare false deny is fail-safe, a missed
# credential write is not. (tr, not ${x,,}: bash-3.2/BSD portable.)
RESOLVED_LC=$(printf '%s' "$RESOLVED" | tr '[:upper:]' '[:lower:]')
for entry in "${CRED_PREFIXES[@]}"; do
  label="${entry%%:*}"
  prefix=$(printf '%s' "${entry#*:}" | tr '[:upper:]' '[:lower:]')
  # Match the directory node itself (no trailing /) as well as anything
  # under it. Without the equality case, a Write whose path resolves to the
  # exact dir (e.g. ~/.ssh) would slip past the dir-tree prefix check.
  case "$RESOLVED_LC" in
    "$prefix"*)         MATCHED_LABEL="$label"; break ;;
    "${prefix%/}")      MATCHED_LABEL="$label"; break ;;
  esac
done
if [ -z "$MATCHED_LABEL" ] && [ "$RESOLVED_LC" = "$(printf '%s' "$NETRC_FILE" | tr '[:upper:]' '[:lower:]')" ]; then
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
