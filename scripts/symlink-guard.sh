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
#   $HOME/.config/gh, $HOME/.netrc (file), /etc, $HOME/.password-store,
#   $HOME/.claude/.credentials.json (file — the OAuth token; the ~/.claude
#   TREE is deliberately not a prefix, it holds legitimate write targets).
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
    p="${p#"//./"}"   # \.\C:\... device-namespace prefix (D182, same mirror)
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
  # Stock BSD/macOS (no GNU realpath/greadlink, or BSD realpath which lacks `-m`).
  # D183: walk the path component-by-component from the root, resolving symlinks
  # at each STILL-EXISTING ancestor via `cd … && pwd -P` (bash 3.2 / BSD safe).
  # Once a component does not exist yet (the common case for a Write that
  # creates new directories), lexically collapse the REMAINING '.'/'..'
  # segments against the last resolved ancestor instead of returning the raw
  # unresolved tail — `cd` failing on ONE missing directory must not
  # short-circuit into a lexical passthrough that leaves '..' unresolved (a
  # Write to <repo>/<newdir>/../../../.ssh/id_rsa was silently ALLOWED before
  # this fix, and a symlinked ancestor with a not-yet-created child, e.g.
  # <repo>/link-to-.ssh/sub/id_rsa, was too). Fail CLOSED throughout.
  _rem="$FILE_PATH"
  case "$_rem" in
    /*) _res="/" ;;
    *)  _res="$PWD/" ;;
  esac
  while [ -n "$_rem" ]; do
    _rem="${_rem#/}"
    _seg="${_rem%%/*}"
    case "$_rem" in */*) _rem="${_rem#*/}" ;; *) _rem="" ;; esac
    case "$_seg" in
      ""|".") continue ;;
      "..")
        _res="${_res%/}"; _res="${_res%/*}"; [ -z "$_res" ] && _res="/"
        continue
        ;;
    esac
    _cand="${_res%/}/$_seg"
    if _rp=$(cd "$_cand" 2>/dev/null && pwd -P); then
      _res="$_rp"
    elif [ -L "$_cand" ]; then
      _tgt=$(readlink -- "$_cand" 2>/dev/null)
      # D183 (follow-up): splicing the target string directly into $_res left
      # any '..' INSIDE a relative target unresolved (`ln -s ../../.ssh/id_rsa
      # repo/notes.txt` produced ".../repo/../../.ssh/id_rsa" verbatim, which
      # never prefix-matches the real credential dir). Re-enter the walk
      # instead: push the target's segments back onto $_rem so the SAME '..'
      # popping logic above collapses them against $_res (relative target) or
      # against '/' (absolute target), rather than a raw lexical splice.
      case "$_tgt" in
        /*) _res="/"; _rem="${_tgt#/}${_rem:+/$_rem}" ;;
        *)  _rem="$_tgt${_rem:+/$_rem}" ;;
      esac
    else
      _res="${_res%/}/$_seg"
    fi
  done
  RESOLVED="$_res"
fi
# Normalize realpath's OUTPUT to the /c/… form so it matches the credential
# prefixes (see the pre-realpath note above — this is the load-bearing half).
RESOLVED=$(sb_normalize_path "$RESOLVED")

SESSION_ID=$(printf '%s' "$RAW" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r' || true)

# D182: NTFS 8.3 short-name components ("SSH~1" for .ssh, "TMP~1.MKZ" for a
# longer temp dir) pass through realpath UNEXPANDED — a credential dir reached
# via its short alias never matches the long-form prefix list below. This was
# originally a blanket deny, but the pattern also matches ordinary long
# filenames that merely contain a tilde+digit (notes~1.md, a CI runner's
# RUNNER~1 temp dir) with nothing to expand — over-blocking normal project
# writes. When `cygpath` is available, ask Windows for the real long-form
# path and evaluate THAT instead: if the target exists, expand it directly;
# if only its parent exists (the common Write-a-new-file case), expand the
# parent and reattach the leaf — `cygpath -l -m` does not expand a leaf that
# is not itself present on disk. Deny outright, before the prefix match, only
# when expansion is unavailable (no cygpath, or nothing on the path exists to
# query) — that is the case this guard genuinely cannot resolve safely.
# 8.3 aliases exist only on Windows filesystems: on Linux/macOS a `NAME~1` component is an
# ordinary filename, so the rule applies only where cygpath is present (native Windows, or
# the suite's stubbed-cygpath Windows lane) or the host is MSYS/Cygwin.
_sn_windows_host=0
if command -v cygpath >/dev/null 2>&1; then _sn_windows_host=1; else
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) _sn_windows_host=1 ;; esac
fi
if [ "$_sn_windows_host" -eq 1 ] && printf '%s\n%s\n' "$FILE_PATH" "$RESOLVED" | grep -qE '(^|/)[^/]*~[0-9]+(\.[^/.]*)?(/|$)'; then
  EXPANDED=""
  if command -v cygpath >/dev/null 2>&1; then
    if [ -e "$RESOLVED" ]; then
      EXPANDED=$(cygpath -l -m -- "$RESOLVED" 2>/dev/null | tr -d '\r')
    else
      _sn_parent="${RESOLVED%/*}"; _sn_leaf="${RESOLVED##*/}"
      if [ -n "$_sn_parent" ] && [ -e "$_sn_parent" ]; then
        _sn_pexp=$(cygpath -l -m -- "$_sn_parent" 2>/dev/null | tr -d '\r')
        [ -n "$_sn_pexp" ] && EXPANDED="$_sn_pexp/$_sn_leaf"
      fi
    fi
    [ -n "$EXPANDED" ] && EXPANDED=$(sb_normalize_path "$EXPANDED")
  fi
  if [ -n "$EXPANDED" ]; then
    RESOLVED="$EXPANDED"
  else
    SHORTNAME_REASON="Write to '$FILE_PATH' (resolved '$RESOLVED') contains an NTFS 8.3 short-name path component (e.g. 'NAME~1') that could not be expanded back to its long form (no cygpath, or nothing on the path exists to query). Symlink-guard denies rather than risk a credential-dir alias slipping past the prefix check. Suppress: SB_SYMLINK_GUARD=off."
    sb_log_audit "symlink-guard.sh" "deny" "ntfs-8.3-shortname" "${TOOL}(${FILE_PATH})" "$SHORTNAME_REASON" "$SESSION_ID"
    jq -nc --arg r "$SHORTNAME_REASON" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
      }
    }' 2>/dev/null || true
    exit 0
  fi
fi

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
# Special case: single credential FILES, not prefix trees. ~/.claude must NOT
# be a prefix entry — plans/, projects/ (memory), settings.json live there and
# are legitimate write targets; only the OAuth token file is a credential.
CRED_FILES=(
  "netrc:$HOME/.netrc"
  "claude-oauth:$HOME/.claude/.credentials.json"
)

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
if [ -z "$MATCHED_LABEL" ]; then
  for entry in "${CRED_FILES[@]}"; do
    label="${entry%%:*}"
    f=$(printf '%s' "${entry#*:}" | tr '[:upper:]' '[:lower:]')
    if [ "$RESOLVED_LC" = "$f" ]; then MATCHED_LABEL="$label"; break; fi
  done
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
