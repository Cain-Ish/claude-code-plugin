#!/bin/bash
# Shared functions for second-brain hook scripts.
# Source this at the top of any hook script: source "$(dirname "$0")/lib.sh"

BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"

# KB single source of truth: exports SB_STRUCTURED_TYPES / SB_CONTENT_CATEGORIES / SB_ALL_CATEGORIES
# / SB_GENERATED_DIRS / SB_EDGE_TYPES / SB_FORGET_PROTECTED / SB_FORGET_DISCOUNTED from kb-schema.json.
# Sourced here so every lib.sh consumer has them. Fail-soft (no-op if jq/manifest absent).
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]:-$0}")/kb-schema.sh" 2>/dev/null || true

# Parse hook input from stdin. Sets: SB_INPUT, SB_SESSION_ID, SB_TRANSCRIPT_PATH, SB_TIMESTAMP
sb_parse_input() {
  SB_INPUT=$(cat)
  SB_SESSION_ID=$(echo "$SB_INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null | tr -d '\r')
  SB_TRANSCRIPT_PATH=$(echo "$SB_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null | tr -d '\r')
  SB_TIMESTAMP=$(date +"%Y-%m-%d")
}

# Echo $1 if it parses as a JSON array; otherwise echo "[]". Used to harden
# --argjson against non-JSON or non-array handoff values. Requires jq.
sb_safe_json_array() {
  local val="${1:-[]}"
  if echo "$val" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "$val"
  else
    echo "[]"
  fi
}

# Log an error to error-log.jsonl for session-load.sh to surface.
# Precondition: caller must ensure $BRAIN_DIR exists (e.g. mkdir -p before
# calling). The 2>/dev/null on the redirect would otherwise swallow the
# "no such file" error and the log entry would be lost silently.
# Falls back to printf-built JSON when jq is missing — otherwise the very
# error we want to log (jq absent) would itself fail silently. The printf
# path strips C0 control chars (U+0000-U+001F) before escaping so a multi-
# line error_msg can't fragment the JSONL record into two malformed lines.
# R6b (HOOK-9): keep a log from growing unboundedly on unattended boxes —
# once past 512KB, keep only the newest 1000 lines (the useful diagnostic
# tail; the Pi accumulated a 9MB error-log before this).
sb_rotate_log() {
  local f="$1" sz
  [ -f "$f" ] || return 0
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$sz" -gt 524288 ] || return 0
  tail -n 1000 "$f" > "$f.tmp.$$" 2>/dev/null \
    && mv "$f.tmp.$$" "$f" 2>/dev/null || rm -f "$f.tmp.$$" 2>/dev/null
}

sb_log_error() {
  local script_name="${1:-unknown}"
  local error_msg="${2:-}"
  local exit_code="${3:-1}"
  local ts target="$BRAIN_DIR/error-log.jsonl"
  # R6b (HOOK-9): gate=* breadcrumbs logged with exit_code 0 are TRACE, not
  # errors — they were 41% of error-log lines and polluted every "tail the
  # error log" diagnosis plus verify.sh's freshness check. Route them to the
  # audit-log (the trajectory channel). A gate= message with a NONZERO exit
  # code is a real failure and stays in the error-log.
  if [ "$exit_code" = "0" ]; then
    case "$error_msg" in gate=*) target="$BRAIN_DIR/audit-log.jsonl" ;; esac
  fi
  # Each log keeps ITS OWN rotation policy: the audit-log is the guard-verdict
  # evidence channel with the larger 5MiB/5000-line window (sb_rotate_audit_log
  # — applying the 512KB error-log cap to it would have truncated ~2MB of live
  # verdict evidence on first trace; R6b review finding). error-log gets the
  # tighter sb_rotate_log cap.
  if [ "$target" = "$BRAIN_DIR/audit-log.jsonl" ]; then
    sb_rotate_audit_log
  else
    sb_rotate_log "$target"
  fi
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg t "$ts" \
      --arg s "$script_name" \
      --arg m "$error_msg" \
      --argjson c "$exit_code" \
      '{timestamp:$t, script:$s, message:$m, exit_code:$c}' \
      >> "$target" 2>/dev/null
  else
    local esc_script esc_msg
    esc_script=$(printf '%s' "$script_name" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_msg=$(printf '%s' "$error_msg" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"timestamp":"%s","script":"%s","message":"%s","exit_code":%s}\n' \
      "$ts" "$esc_script" "$esc_msg" "$exit_code" \
      >> "$target" 2>/dev/null
  fi
}

# --- Audit log (v2.9.0, HarnessAudit Layer 1) ----------------------------
# Trajectory log separate from error-log.jsonl. Captures every guard verdict
# (allow / ask / deny / flag) emitted by persona-tool-guard, tool-return
# scanner, wiki-write guard, etc. The intent is the HarnessAudit principle:
# evidence collected from a channel the agent can't manipulate, used later
# by /second-brain:audit to surface what the safety layer actually did.
#
# Schema (JSONL, one line per event):
#   { ts, hook, verdict, rule, target, reason, session_id, extra }
#
# Bounded by sb_rotate_audit_log: 5000 lines / 5 MB cap, oldest 50% dropped.
# Append is fail-soft (2>/dev/null on every write) so a guard hook never
# blocks a tool call because the audit file is unwritable.
SB_AUDIT_FILE="$BRAIN_DIR/audit-log.jsonl"
SB_AUDIT_MAX_LINES=5000
SB_AUDIT_MAX_BYTES=5242880   # 5 MiB

sb_log_audit() {
  local hook="${1:-unknown}"
  local verdict="${2:-allow}"        # allow | ask | deny | flag
  local rule="${3:-}"
  local target="${4:-}"
  local reason="${5:-}"
  local session_id="${6:-${SB_SESSION_ID:-}}"
  local extra_json="${7:-{\}}"        # raw JSON object; '{}' when omitted
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  mkdir -p "$BRAIN_DIR" 2>/dev/null || return 0

  if command -v jq >/dev/null 2>&1; then
    if ! echo "$extra_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
      extra_json='{}'
    fi
    jq -nc \
      --arg t "$ts" --arg h "$hook" --arg v "$verdict" \
      --arg r "$rule" --arg target "$target" --arg reason "$reason" \
      --arg sid "$session_id" --argjson x "$extra_json" \
      '{ts:$t, hook:$h, verdict:$v, rule:$r, target:$target, reason:$reason, session_id:$sid, extra:$x}' \
      >> "$SB_AUDIT_FILE" 2>/dev/null
  else
    # jq absent — fall back to printf-built JSON, stripping C0 control chars
    # so multi-line reasons cannot fragment a JSONL record into two.
    local esc_h esc_r esc_t esc_reason esc_sid
    esc_h=$(printf '%s' "$hook"      | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_r=$(printf '%s' "$rule"      | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_t=$(printf '%s' "$target"    | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_reason=$(printf '%s' "$reason" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_sid=$(printf '%s' "$session_id" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"ts":"%s","hook":"%s","verdict":"%s","rule":"%s","target":"%s","reason":"%s","session_id":"%s","extra":{}}\n' \
      "$ts" "$esc_h" "$verdict" "$esc_r" "$esc_t" "$esc_reason" "$esc_sid" \
      >> "$SB_AUDIT_FILE" 2>/dev/null
  fi
}

# Rotate audit-log when it exceeds line or byte caps. Drops the oldest 50%
# of lines (not the newest) so recent decisions remain queryable. Idempotent:
# safe to call from any hook; no-op when caps not exceeded.
sb_rotate_audit_log() {
  [ -f "$SB_AUDIT_FILE" ] || return 0
  local lines bytes
  lines=$(wc -l < "$SB_AUDIT_FILE" 2>/dev/null | tr -d ' ')
  bytes=$(wc -c < "$SB_AUDIT_FILE" 2>/dev/null | tr -d ' ')
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=0
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  if [ "$lines" -gt "$SB_AUDIT_MAX_LINES" ] || [ "$bytes" -gt "$SB_AUDIT_MAX_BYTES" ]; then
    local keep=$(( lines / 2 ))
    [ "$keep" -lt 1 ] && keep=1
    local tmp="$SB_AUDIT_FILE.tmp.$$"
    tail -n "$keep" "$SB_AUDIT_FILE" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$SB_AUDIT_FILE" \
      || rm -f "$tmp" 2>/dev/null
  fi
}

# Regenerate wiki/index.md catalog after wiki writes.
# Plugin root is taken from $CLAUDE_PLUGIN_ROOT when the hook harness sets it,
# falling back to the lib.sh location (../) for manual invocation and tests.
sb_reindex_wiki() {
  local knowledge_dir="${1:-${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}}"
  knowledge_dir="${knowledge_dir/#\~/$HOME}"
  local plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
  if [ -z "$plugin_root" ] || [ ! -d "$plugin_root" ]; then
    # ${BASH_SOURCE[0]} is this lib.sh; its parent is scripts/, grandparent is plugin root.
    plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd) || plugin_root=""
  fi
  local reindex_js="$plugin_root/mcp/dist/tools/knowledge-reindex.bundle.js"
  if command -v node >/dev/null 2>&1 && [ -f "$reindex_js" ]; then
    # Dynamic ESM import requires --input-type=module + await import().
    # The previous `import { x } from process.env.SB_BUNDLE` form silently
    # parse-errored (no string literal) and never reindexed.
    # Error path: route stderr to the error-log so a corrupted bundle or
    # missing-export failure surfaces in the next session-load banner
    # instead of silently leaving the wiki index stale.
    local _reindex_err
    _reindex_err=$(SB_BUNDLE="$reindex_js" SB_KDIR="$knowledge_dir" \
      node --input-type=module -e "
        const { pathToFileURL } = await import('node:url');
        const m = await import(pathToFileURL(process.env.SB_BUNDLE).href);
        await m.knowledgeReindex(process.env.SB_KDIR);
      " 2>&1 >/dev/null) || true
    if [ -n "$_reindex_err" ]; then
      sb_log_error "sb_reindex_wiki" "reindex-failed: $(printf '%s' "$_reindex_err" | tr '\n' ' ' | head -c 200)" 0
    fi
  fi
}

# Run the SAME node-shaper (knowledge_validate autofix) the maintainer uses, on
# an ARBITRARY wiki dir — so the dream can normalize its STAGING pages to the
# maintainer's exact format (canonical frontmatter, β related:/tags:, patched
# required fields) before they are reviewed or merged onto live. The MCP
# knowledge_validate tool is pinned to the startup KNOWLEDGE_DIR; this helper
# points the bundle at any dir, mirroring sb_reindex_wiki. Echoes the autofix
# count. The dir must contain a wiki/ subtree (we pass its PARENT as knowledgeDir).
sb_validate_wiki() {
  local knowledge_dir="${1:-${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}}"
  knowledge_dir="${knowledge_dir/#\~/$HOME}"
  local plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
  if [ -z "$plugin_root" ] || [ ! -d "$plugin_root" ]; then
    plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd) || plugin_root=""
  fi
  local validate_js="$plugin_root/mcp/dist/tools/knowledge-validate.bundle.js"
  if command -v node >/dev/null 2>&1 && [ -f "$validate_js" ]; then
    local _val_err _verr
    _verr=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/.sb-validate-err.$$")   # unique + honors $TMPDIR; was a fixed /tmp name (race + ignored TMPDIR)
    _val_err=$(SB_BUNDLE="$validate_js" SB_KDIR="$knowledge_dir" \
      node --input-type=module -e "
        const { pathToFileURL } = await import('node:url');
        const m = await import(pathToFileURL(process.env.SB_BUNDLE).href);
        const r = await m.knowledgeValidate(process.env.SB_KDIR, { autofix: true });
        process.stdout.write(String(r.fixed || 0));
      " 2>"$_verr") || true
    _val_err_msg=$(cat "$_verr" 2>/dev/null); rm -f "$_verr" 2>/dev/null
    if [ -n "$_val_err_msg" ]; then
      sb_log_error "sb_validate_wiki" "validate-failed: $(printf '%s' "$_val_err_msg" | tr '\n' ' ' | head -c 200)" 0
    fi
    printf '%s' "${_val_err:-0}"
  else
    printf '0'
  fi
}

# (P5 fix, 0.24.49: a SECOND sb_validate_wiki definition lived here and, being
# the last def, shadowed the count-returning one above — so dream-accept's
# "Normalized N pages" telemetry was always silent. Deleted; the count-returning
# definition above is now the sole one. The ensure-dirs.sh / maintain-
# deterministic.sh callers redirect stdout to /dev/null, so the extra count is
# backward-compatible.)

# Pure auto-accept decision (0.25.0 autonomy). Given the config mode and the
# dream's state, echo exactly one of: accept | skip:disabled | skip:not-completed
# | skip:already-accepted | skip:safe-refuses-forget. Pure (no I/O) so it is
# tested directly against real input→output pairs, not re-asserted through its
# own caller. The caller does the backup + dream-accept only on "accept".
#   $1 mode (off|safe|all)  $2 status  $3 archived_at  $4 has_forget (0|1)
sb_auto_accept_decision() {
  case "${1:-off}" in off|''|null) echo "skip:disabled"; return ;; esac
  [ "${2:-}" = "completed" ] || { echo "skip:not-completed"; return; }
  case "${3:-}" in ''|null) : ;; *) echo "skip:already-accepted"; return ;; esac
  if [ "${1}" = "safe" ] && [ "${4:-0}" = "1" ]; then echo "skip:safe-refuses-forget"; return; fi
  echo "accept"
}

# Pin a preference line to USER.md. Adds a dated entry with case-insensitive
# dedupe and a 2200-byte cap (aligned with hot-tier budget: USER.md + PROJECT.md
# target ~3200 bytes total). Returns 0 on success, 1 on skip.
sb_pin_to_user() {
  local text="${1:?sb_pin_to_user: text required}"
  local user_file="$BRAIN_DIR/USER.md"
  local max_bytes=2200
  local today
  today=$(date -u +%Y-%m-%d)
  local new_line="- [$today] $text"

  local content=""
  if [ -f "$user_file" ]; then
    content=$(cat "$user_file")
  else
    mkdir -p "$BRAIN_DIR"
    content="# USER preferences

## Pinned"
  fi

  if echo "$content" | grep -qiF "$text"; then
    return 1
  fi

  local projected
  projected=$(printf '%s\n%s\n' "$content" "$new_line")
  local byte_count
  byte_count=$(printf '%s' "$projected" | wc -c | tr -d ' ')
  if [ "$byte_count" -gt "$max_bytes" ]; then
    return 1
  fi

  printf '%s\n' "$projected" > "$user_file"
  return 0
}

# Portable canonicalization of a path to an absolute, symlink-resolved form. Works on GNU
# (realpath / readlink -f) AND stock macOS/BSD where NEITHER exists, via a `cd … && pwd -P`
# parent-resolve plus a one-level leaf deref — the same doctrine as scripts/symlink-guard.sh.
# Echoes the resolved path; returns non-zero (and echoes nothing) only if even the parent dir
# cannot be resolved. WHY: bare `readlink -f` yields empty on stock macOS, which silently broke
# dream-accept.sh's symlink-escape scan (every staged symlink looked out-of-tree → every accept
# refused, incl. the legit security/latest.md alias). Guarded by test-dream-lifecycle.sh 5e/5f.
sb_realpath() {
  local p="${1:-}" r=""
  [ -n "$p" ] || return 1
  r=$(realpath -- "$p" 2>/dev/null) && [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
  r=$(readlink -f -- "$p" 2>/dev/null) && [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
  r=$(greadlink -f -- "$p" 2>/dev/null) && [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
  # Stock BSD/macOS (no GNU realpath/greadlink, BSD readlink without -f): resolve the parent's
  # symlinks via `cd … && pwd -P` (bash 3.2 / BSD safe), then deref the leaf if it is a symlink.
  # The leaf deref is one level: the `cd … && pwd -P` below resolves all symlink DIRECTORY
  # components of the (re-decomposed) target, but a multi-hop FILE-symlink leaf (a→b→c, all files)
  # is resolved only one hop. Safe for the escape scan — `find -type l` lists every staged link, so
  # an unresolved next hop is itself scanned (and flagged if it escapes) independently.
  local _pd _pb _rpd _tgt
  _pd=$(dirname -- "$p"); _pb=$(basename -- "$p")
  _rpd=$(cd "$_pd" 2>/dev/null && pwd -P) || return 1
  if [ -L "$_rpd/$_pb" ]; then
    _tgt=$(readlink -- "$_rpd/$_pb" 2>/dev/null)
    case "$_tgt" in
      /*) p="$_tgt" ;;
      *)  p="$_rpd/$_tgt" ;;
    esac
  else
    p="$_rpd/$_pb"
  fi
  # Canonicalize the final target. A DIRECTORY target (incl. a `.`/`..`-trailing one) is
  # cd-resolved WHOLE so a trailing `..` is COLLAPSED — else `…/wiki/..` would be echoed verbatim
  # and glob-match the caller's in-tree prefix `…/wiki/*`, letting a symlink that points ABOVE
  # the tree (e.g. `ln -s ../..`) escape the guard. A file target keeps its leaf but resolves its
  # parent's symlinks. Fail CLOSED (empty -> caller flags it) if either cd fails (dangling/escaping).
  if [ -d "$p" ]; then
    _rpd=$(cd "$p" 2>/dev/null && pwd -P) || return 1
    printf '%s\n' "$_rpd"
  else
    _pd=$(dirname -- "$p"); _pb=$(basename -- "$p")
    _rpd=$(cd "$_pd" 2>/dev/null && pwd -P) || return 1
    printf '%s\n' "$_rpd/$_pb"
  fi
}

# Normalize a project directory path → slug. Collapses tmp/scratch-style dirs
# into one shared "scratch" project (mirrors slugFromProjectDir in the MCP server,
# so the bash and TS resolvers agree on the same slug for the same dir).
sb_slug_from_dir() {
  # tr -d '\r': a CRLF-tainted CLAUDE_PROJECT_DIR (Windows) would yield a slug like "demo\r"
  # → a ghost project dir + split-brain vs every pin/marker keyed on the clean slug. Strip
  # CR before basename so the bash slug matches the (also-sanitized) MCP slugFromProjectDir.
  local raw; raw=$(printf '%s' "${1:-}" | tr -d '\r')
  local base; base=$(basename "$raw")
  case "$base" in
    tmp.*|tmp|.tmp.*|tmpfs|"") echo "scratch" ;;
    *) echo "$base" ;;
  esac
}

# Resolve the active project slug. Precedence: CLAUDE_PROJECT_DIR > pin > cwd.
# CLAUDE_PROJECT_DIR is the PER-SESSION project root Claude Code sets — checked
# FIRST so a concurrent session in another project can't hijack this session's
# scoping (the bug: the old order trusted the pin first). The global
# .active-session-slug pin is a single shared file the last session's SessionStart
# overwrites; it stays BELOW CLAUDE_PROJECT_DIR but ABOVE bare cwd (it is
# project-root level and survives a subdir cwd) — the legacy path for CLIs that
# expose no project dir.
sb_resolve_slug() {
  local cwd="${1:-$PWD}" _s
  # 1. CLAUDE_PROJECT_DIR — per-process project root (set by Claude Code when present).
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    _s=$(sb_slug_from_dir "$CLAUDE_PROJECT_DIR")
    case "$_s" in /|.|..) ;; *) echo "$_s"; return 0 ;; esac
  fi
  # 2. cwd, but ONLY when its basename names a KNOWN project (projects/<slug>/ exists).
  #    cwd is per-process, so it can't be clobbered by a concurrent session like the shared
  #    pin can — but the known-project gate rejects a subdir cwd (→ falls to the pin below).
  _s=$(sb_slug_from_dir "$cwd")
  case "$_s" in /|.|..) _s="" ;; esac
  if [ -n "$_s" ] && [ -f "$BRAIN_DIR/projects/$_s/PROJECT.md" ]; then echo "$_s"; return 0; fi
  # 3. The pin (session-root level; survives a subdir cwd) — subdir/legacy fallback.
  local pinned="$BRAIN_DIR/.active-session-slug" slug
  if [ -f "$pinned" ]; then
    slug=$(tr -d '[:space:]' < "$pinned")
    if [ -n "$slug" ] && [ -f "$BRAIN_DIR/projects/$slug/PROJECT.md" ]; then echo "$slug"; return 0; fi
  fi
  # 4. Last resort: the (already-normalized) cwd basename in $_s — a brand-new project not yet
  #    scaffolded. Empty when the cwd was degenerate (blanked above), matching the TS resolver
  #    returning undefined; callers then report "could not resolve" rather than emit a "/" slug.
  echo "$_s"
}

# Strip markdown code fences from LLM output. Models sometimes wrap JSON in
# ```json ... ``` despite being told not to. Reads stdin, writes stdout.
sb_strip_code_fences() {
  sed '1s/^```[a-zA-Z]*[[:space:]]*//' | sed '$ s/[[:space:]]*```[[:space:]]*$//'
}

# --- Extraction marker helpers ---
# Track which transcript lines have been extracted. Keys are SESSION-scoped
# (slug--session_id, R1.2): pre-compact and stop process disjoint windows of
# one session, repeated Stop firings resume where the last finished (instead
# of re-archiving from line 0 — the 18x-duplicate-archive bug), and two
# concurrent sessions in one project cannot race each other's marker.
# Stale markers are swept by extract-drain.sh after 30 days (kept past the
# review skill's 14-day staleness window so its signal stays observable).

sb_get_extraction_marker() {
  local slug="$1"
  local marker_file="$BRAIN_DIR/.last-extracted-line-$slug"
  if [ -f "$marker_file" ]; then
    local val
    val=$(cat "$marker_file" 2>/dev/null | tr -d '[:space:]')
    if [[ "$val" =~ ^[0-9]+$ ]]; then echo "$val"; else echo "0"; fi
  else
    echo "0"
  fi
}

sb_set_extraction_marker() {
  local slug="$1" line="$2"
  echo "$line" > "$BRAIN_DIR/.last-extracted-line-$slug"
}

sb_clear_extraction_marker() {
  local slug="$1"
  rm -f "$BRAIN_DIR/.last-extracted-line-$slug"
}

# Compose the extraction-marker key for a (slug, session) pair. The session id
# is sanitized for filename safety (it comes from the hook payload).
sb_extraction_marker_key() {
  local slug="$1" sid
  sid=$(printf '%s' "${2:-unknown}" | tr -cd 'A-Za-z0-9._-')
  [ -n "$sid" ] || sid="unknown"
  printf '%s--%s' "$slug" "$sid"
}

# Sanitize a slug for safe filesystem use. Strips path separators, dots,
# and non-alphanumeric chars. Returns 1 if result is empty.
sb_sanitize_slug() {
  local raw="${1:-}"
  local clean
  clean=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g; s/^-//; s/-$//' | head -c 60)
  [ -z "$clean" ] && return 1
  printf '%s' "$clean"
}

# Preprocess JSONL transcript lines on stdin into a compact text summary.
# Shared by stop-extract.sh and pre-compact.sh.
sb_preprocess_transcript() {
  jq -cr '
    if .type == "user" then
      if (.message.content | type) == "string" then
        "USER: " + .message.content
      else
        [.message.content[]? | select(.type == "text") | .text]
        | select(length > 0)
        | "USER: " + join("\n")
      end
    elif .type == "assistant" then
      [.message.content[]? | (
        if .type == "text" then "  " + .text
        elif .type == "tool_use" then
          "  [" + .name + "] " + (
            if .name == "Edit" or .name == "Write" or .name == "Read" then
              (.input.file_path // "")
            elif .name == "Bash" then
              (.input.command // "" | .[0:120])
            else
              (.input | keys | join(",") | .[0:60])
            end
          )
        elif .type == "thinking" then
          "  (thinking: " + (.thinking // "" | .[0:100]) + "...)"
        else empty end
      )] | select(length > 0) | "ASSISTANT:\n" + join("\n")
    else empty end
  ' 2>/dev/null
}

# --- Transcript archive helpers ---
# Archive a preprocessed transcript window for dream mining.
# Appends to an existing archive file for the same session (pre-compact
# runs first, stop appends later), so the full session is captured.
# Args: $1=transcript_path $2=slug $3=session_id $4=start_line $5=end_line $6=tool_count
sb_archive_transcript() {
  local transcript="$1" slug="$2" session_id="$3"
  local start_line="$4" end_line="$5" tool_count="$6"
  local archive_dir="$BRAIN_DIR/transcripts"
  mkdir -p "$archive_dir" 2>/dev/null || return 1
  local date_str
  date_str=$(date +%Y-%m-%d)
  local archive_file="$archive_dir/${session_id}_${slug}_${date_str}.txt"

  if [ ! -f "$archive_file" ]; then
    {
      echo "--- session-meta ---"
      echo "session_id: $session_id"
      echo "project_slug: $slug"
      echo "date: $date_str"
      echo "tool_count: $tool_count"
      echo "line_count: $((end_line - start_line + 1))"
      echo "---"
      echo ""
    } > "$archive_file"
  fi

  sed -n "${start_line},${end_line}p" "$transcript" \
    | sb_preprocess_transcript >> "$archive_file" 2>/dev/null
  sb_prune_transcripts
}

# Archive a subagent's FINAL RESULT (not its full transcript) for dream mining +
# episodic search. Keyed on agent_id so it never collides with a main-session
# archive and de-dupes per agent. The result is already prose (the subagent's last
# assistant text block), so it is written plain under an ASSISTANT: marker — NOT
# through sb_preprocess_transcript (which parses raw JSONL lines). The file matches
# the episodic indexer's session-meta + ASSISTANT body shape, so it is indexed with
# no indexer change. See docs/specs/2026-05-29-subagent-capture-design.md.
# Args: $1=agent_id $2=agent_type $3=slug $4=session_id $5=tool_count $6=result_text
sb_archive_subagent_result() {
  local agent_id="$1" agent_type="$2" slug="$3" session_id="$4" tool_count="$5" result="$6"
  local archive_dir="$BRAIN_DIR/transcripts"
  mkdir -p "$archive_dir" 2>/dev/null || return 1
  local date_str safe_aid
  date_str=$(date +%Y-%m-%d)
  # sanitize agent_id for use as a filename component (defense in depth — it comes
  # from the hook payload). Keep only filename-safe chars; bail if it empties out.
  safe_aid=$(printf '%s' "$agent_id" | tr -cd 'A-Za-z0-9._-')
  [ -n "$safe_aid" ] || safe_aid="unknown"
  local archive_file="$archive_dir/sub-${safe_aid}_${slug}_${date_str}.txt"

  {
    echo "--- session-meta ---"
    echo "session_id: $session_id"
    echo "project_slug: $slug"
    echo "agent_type: $agent_type"
    echo "agent_id: $safe_aid"
    echo "date: $date_str"
    echo "tool_count: $tool_count"
    echo "subagent_result: true"
    echo "---"
    echo ""
    printf 'ASSISTANT:\n%s\n' "$result"
  } > "$archive_file"

  # Prune subagent archives under their OWN budget FIRST, so a busy multi-agent
  # session (hundreds of subagents) can never crowd main-session archives out of
  # the shared 100-file cap. Oldest sub-*.txt by mtime are dropped beyond the cap.
  local sub_cap="${SB_SUBAGENT_ARCHIVE_CAP:-50}"
  local sub_files sub_count
  # newest-first by mtime; delete everything past the cap. -printf is GNU; fall
  # back to a stat-based sort on BSD/macOS.
  sub_files=$(find "$archive_dir" -maxdepth 1 -name 'sub-*.txt' -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | cut -d' ' -f2-)
  if [ -z "$sub_files" ]; then
    sub_files=$(find "$archive_dir" -maxdepth 1 -name 'sub-*.txt' -type f 2>/dev/null \
      | while IFS= read -r f; do printf '%s %s\n' "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)" "$f"; done \
      | sort -rn | cut -d' ' -f2-)
  fi
  sub_count=$(printf '%s\n' "$sub_files" | grep -c . 2>/dev/null || true)
  if [ "$sub_count" -gt "$sub_cap" ]; then
    printf '%s\n' "$sub_files" | tail -n +"$((sub_cap + 1))" | while IFS= read -r f; do
      [ -n "$f" ] && rm -f "$f"
    done
  fi

  sb_prune_transcripts
}

# Write a machine-GENERATED wiki page with born-valid frontmatter (R5.1 —
# generated-page contract; deep-review CR-007/SCRIPTS-06/MCP-CHURN-1). The churn
# class this kills: a frontmatter-less generated page gets autofixed by
# knowledge_validate, then clobbered back (frontmatter stripped) by the next
# capture run — forever. Born-valid ends the loop, and wiki/state/ keeps
# generated pages searchable (root-level pages are never indexed).
# Body comes from STDIN; the write is atomic; `created:` survives regeneration.
# Args: $1=absolute output path  $2=title  $3=description
sb_write_generated_page() {
  local out="$1" title="$2" desc="$3"
  local today created tmp
  # Strip double quotes from YAML-quoted values (deep-review: an embedded quote
  # would produce invalid YAML and re-create the autofix churn for any caller).
  title=$(printf '%s' "$title" | tr -d '"')
  desc=$(printf '%s' "$desc" | tr -d '"')
  today=$(date -u +%F)
  created="$today"
  if [ -f "$out" ]; then
    created=$(sed -n 's/^created:[[:space:]]*//p' "$out" | head -1)
    [ -n "$created" ] || created="$today"
  fi
  mkdir -p "$(dirname "$out")" 2>/dev/null || return 1
  tmp="${out}.tmp.$$"
  {
    printf -- '---\n'
    printf 'title: "%s"\n' "$title"
    printf 'description: "%s"\n' "$desc"
    printf 'type: state\n'
    printf 'generated: true\n'
    printf 'created: %s\n' "$created"
    printf 'updated: %s\n' "$today"
    # tags + related complete the canonical 7-field required set (knowledge-validate
    # REQUIRED_FM_FIELDS). Without them the page is born INCOMPLETE: validate autofix
    # patches tags:[]/related:[] every reindex, then the next Stop-hook regeneration
    # strips them — eternal churn. Empty lists match exactly what the autofix emits
    # (related:[] is also what the graph projector writes for an edgeless page), so the
    # page is genuinely born-valid and round-trips clean. THIS is the "stops churning"
    # the helper's contract promises.
    printf 'tags: []\n'
    printf 'related: []\n'
    printf -- '---\n'
    printf '<!-- generated: do not hand-edit — regenerated by the writing hook -->\n\n'
    cat
  } > "$tmp" 2>/dev/null && mv "$tmp" "$out" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# Enforce transcript archive caps: 100 files max, 5MB total.
# Deletes oldest files first (sorted by filename which embeds date).
sb_prune_transcripts() {
  local archive_dir="$BRAIN_DIR/transcripts"
  [ -d "$archive_dir" ] || return 0

  local files
  files=$(find "$archive_dir" -name '*.txt' -type f 2>/dev/null | sort)
  local count
  count=$(echo "$files" | grep -c . 2>/dev/null || true)

  while [ "$count" -gt 100 ]; do
    local oldest
    oldest=$(echo "$files" | head -1)
    [ -n "$oldest" ] && rm -f "$oldest"
    files=$(echo "$files" | tail -n +2)
    count=$((count - 1))
  done

  local total_bytes=0
  for f in $files; do
    local sz
    sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
    total_bytes=$((total_bytes + sz))
  done

  while [ "$total_bytes" -gt 5242880 ] && [ -n "$files" ]; do
    local oldest
    oldest=$(echo "$files" | head -1)
    [ -z "$oldest" ] && break
    local sz
    sz=$(wc -c < "$oldest" 2>/dev/null | tr -d ' ')
    rm -f "$oldest"
    total_bytes=$((total_bytes - sz))
    files=$(echo "$files" | tail -n +2)
  done
}

# --- Session-cadence + maintenance flags ---------------------------------
# Track substantive sessions per project so SessionStart can prompt for
# /second-brain:dream after a threshold without manual reminders. The flag
# files are per-project under $BRAIN_DIR/projects/<slug>/ so a noisy project
# doesn't trigger banners on quiet ones.

sb_increment_session_count() {
  local slug="$1"
  local f="$BRAIN_DIR/projects/$slug/.session-count"
  mkdir -p "$(dirname "$f")" 2>/dev/null
  local n=0
  [ -f "$f" ] && n=$(tr -d '[:space:]' < "$f" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%d' "$((n + 1))" > "$f"
}

sb_get_session_count() {
  local f="$BRAIN_DIR/projects/$1/.session-count"
  local n=0
  [ -f "$f" ] && n=$(tr -d '[:space:]' < "$f" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%d' "$n"
}

sb_reset_session_count() { echo 0 > "$BRAIN_DIR/projects/$1/.session-count" 2>/dev/null; }

# --- v2.8.0 maintainer auto-dispatch state helpers ----------------------
# Per-project wiki-write counter. session-load.sh consumes this at the
# threshold and dispatches the maintainer subagent.

sb_inc_wiki_writes() {  # $1 = project slug
  local f="$BRAIN_DIR/projects/$1/.wiki-writes"
  mkdir -p "$(dirname "$f")" 2>/dev/null
  local n=0
  # Preflight existence check — bash emits "No such file" to stderr before tr
  # runs if the file is missing; 2>/dev/null on tr does not suppress it.
  [ -f "$f" ] && n=$(tr -d '[:space:]' < "$f" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%d' "$((n+1))" > "$f.tmp" && mv "$f.tmp" "$f"
}

sb_get_wiki_writes() {  # $1 = slug
  local f="$BRAIN_DIR/projects/$1/.wiki-writes"
  local n=0
  [ -f "$f" ] && n=$(tr -d '[:space:]' < "$f" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  echo "$n"
}

sb_set_wiki_writes() {  # $1 = slug, $2 = int
  [[ "$2" =~ ^[0-9]+$ ]] || return 1
  local f="$BRAIN_DIR/projects/$1/.wiki-writes"
  mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '%d' "$2" > "$f.tmp" && mv "$f.tmp" "$f"
}

sb_reset_wiki_writes() { sb_set_wiki_writes "$1" 0; }

sb_inc_maintainer_fails() {  # $1 = slug
  local f="$BRAIN_DIR/projects/$1/.maintainer-fail-count"
  mkdir -p "$(dirname "$f")" 2>/dev/null
  local n=0
  [ -f "$f" ] && n=$(tr -d '[:space:]' < "$f" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%d' "$((n+1))" > "$f.tmp" && mv "$f.tmp" "$f"
}

sb_get_maintainer_fails() {  # $1 = slug
  local f="$BRAIN_DIR/projects/$1/.maintainer-fail-count"
  local n=0
  [ -f "$f" ] && n=$(tr -d '[:space:]' < "$f" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  echo "$n"
}

sb_reset_maintainer_fails() { rm -f "$BRAIN_DIR/projects/$1/.maintainer-fail-count"; }

# Pin candidate queue — populated from extracted persona_signals;
# session-load.sh banners the count so user can /pin with one prompt.
sb_append_pin_candidate() {
  local slug="$1" text="$2"
  local f="$BRAIN_DIR/projects/$slug/.pin-candidates.jsonl"
  mkdir -p "$(dirname "$f")" 2>/dev/null
  jq -nc --arg t "$(date -u +%FT%TZ)" --arg p "$text" '{at:$t, text:$p}' >> "$f" 2>/dev/null
}

sb_count_pin_candidates() {
  local f="$BRAIN_DIR/projects/$1/.pin-candidates.jsonl"
  [ -f "$f" ] && wc -l < "$f" 2>/dev/null | tr -d ' ' || echo 0
}

# Folded count of status:open structural conflicts in <knowledge_dir>/graph/conflicts.jsonl.
# The sidecar is append-only; a conflict's CURRENT status is its last-appended line, so we
# fold by identity (from,type,to,kind) and count those whose latest line is "open".
sb_conflicts_open_count() {
  local kd="${1:-$HOME/knowledge}"; kd="${kd/#\~/$HOME}"
  local f="$kd/graph/conflicts.jsonl"
  [ -s "$f" ] || { echo 0; return 0; }
  # Reduce-keyed fold = explicit "last-appended line wins" per identity (depends only on
  # documented jq object last-write-wins, not on group_by sort-stability). Per-line tolerant:
  # a torn/partial last line is skipped (fromjson?) rather than zeroing the whole count.
  jq -nR 'reduce (inputs|fromjson?) as $r ({}; .[($r|[.from,.type,.to,.kind]|tojson)]=$r)
          | [.[]] | map(select(.status=="open")) | length' "$f" 2>/dev/null || echo 0
}

# --- Dream lifecycle helpers ---

sb_generate_dream_id() {
  echo "drm_$(date -u +%Y%m%dT%H%M%SZ)"
}

# (R6 sweep: the sb_dream_dir/sb_dream_status helpers were deleted — nothing
# referenced them; dream paths are composed inline as "$BRAIN_DIR/dreams/<id>"
# and status reads are inline jq, the canonical pattern across the scripts.)

sb_dream_set_status() {
  local dream_id="$1" field="$2" value="$3"
  local status_file="$BRAIN_DIR/dreams/$dream_id/status.json"
  [ -f "$status_file" ] || return 1
  local tmp
  tmp=$(mktemp)
  if [ "$value" = "null" ]; then
    jq --arg f "$field" '.[$f] = null' "$status_file" > "$tmp" && mv "$tmp" "$status_file"
  elif echo "$value" | jq -e 'type == "number"' >/dev/null 2>&1; then
    jq --arg f "$field" --argjson v "$value" '.[$f] = $v' "$status_file" > "$tmp" && mv "$tmp" "$status_file"
  else
    jq --arg f "$field" --arg v "$value" '.[$f] = $v' "$status_file" > "$tmp" && mv "$tmp" "$status_file"
  fi
}

# Single source of truth for "is this dream wedged?" — the one staleness policy
# shared by dream-snapshot.sh (deadlock-break before staging a new dream),
# dream-autostage.sh (reclaim a never-started pending), verify.sh (health
# report), and maintain-llm-drain.sh (post-run self-heal). Before this helper
# the four disagreed (6h mtime / 24h created_at / calendar-day / none), which
# produced contradictory health verdicts and a double-reclaim race.
#
# Policy: status is pending|running AND status.json mtime is older than
# SB_DREAM_RUN_TIMEOUT (default 21600s = 6h). mtime is the liveness signal —
# the dream-runner re-stamps status.json (status=running) between phases, so a
# healthy run keeps it fresh; a crashed run goes quiet and ages out. A terminal
# status (completed/failed/canceled) or a missing file is never stale.
#
# $1 = path to a dream's status.json. Echoes nothing.
# Returns 0 = stale (caller may reclaim to failed), 1 = fresh / terminal / missing.
sb_dream_is_stale() {
  local sf="${1:-}"
  [ -f "$sf" ] || return 1
  local s
  s=$(jq -r '.status // ""' "$sf" 2>/dev/null | tr -d '\r')
  case "$s" in
    pending|running) : ;;
    *) return 1 ;;
  esac
  local run_to="${SB_DREAM_RUN_TIMEOUT:-21600}"
  case "$run_to" in ''|*[!0-9]*) run_to=21600 ;; esac
  local smt now
  smt=$(stat -c %Y "$sf" 2>/dev/null || stat -f %m "$sf" 2>/dev/null || echo 0)
  now=$(date +%s)
  [ "$(( now - ${smt:-0} ))" -gt "$run_to" ]
}

# --- Extractor backend & health tracking ---------------------------------
# Unified entry point for both stop-extract.sh and pre-compact.sh. Tries the
# `claude` CLI first; if its auth is broken, falls back to a direct Messages
# API call via curl using $ANTHROPIC_API_KEY. Writes a health marker to
# $BRAIN_DIR/.extractor-health.json so session-load.sh can surface the state
# to the user on the next SessionStart, instead of failing silently.

SB_HEALTH_FILE="$BRAIN_DIR/.extractor-health.json"

# Write health snapshot. $1=backend ("claude-cli"|"anthropic-api"|"none"),
# $2=ok|fail, $3=reason (short string). Writes atomically via tempfile-rename
# so concurrent readers from session-load.sh never see a half-truncated file
# when stop and pre-compact hooks fire in quick succession.
sb_write_extractor_health() {
  local backend="$1" status="$2" reason="${3:-}"
  local ts
  ts=$(date -u +%FT%TZ)
  mkdir -p "$BRAIN_DIR" 2>/dev/null
  if command -v jq >/dev/null 2>&1; then
    local tmp="$SB_HEALTH_FILE.tmp.$$"
    jq -nc --arg t "$ts" --arg b "$backend" --arg s "$status" --arg r "$reason" \
      '{checked_at:$t, backend:$b, status:$s, reason:$r}' \
      > "$tmp" 2>/dev/null \
      && mv "$tmp" "$SB_HEALTH_FILE" \
      || rm -f "$tmp" 2>/dev/null
  fi
}

# Call configured extractor. Reads stdin from $1 file, writes JSON to $2.
# $3 = model id, $4 = system prompt, $5 = timeout seconds.
# Returns 0 if output exists and is a JSON object, 1 otherwise.
# Always writes a health marker before returning.
# Strip ANSI/VT control sequences from $1, write cleaned bytes to stdout.
# Required because `script -qfc` (Backend 1b) blends pty escape codes into
# stdout — without stripping, jq sees garbage and the extraction is wasted.
# Handles both OSC terminators: BEL and ST (ESC \). Strips in order: OSC-BEL,
# OSC-ST, CSI, single-char ESC sequences, then CR.
# PORTABILITY (0.28.2): the control bytes are built in BASH via $'\xNN' (ANSI-C
# quoting, bash 3.2-safe — the same idiom persona-tool-guard.sh uses) and
# interpolated as LITERAL bytes. The previous `\x1b`/`\x07` inside the sed
# program were GNU-sed-only — BSD/macOS sed treats `\x` as a literal 'x', so it
# stripped NOTHING and pty escape codes leaked into the extracted wiki content.
sb_strip_ansi() {
  local _esc _bel _cr
  _esc=$'\x1b'; _bel=$'\x07'; _cr=$'\r'
  sed -E "
    s/${_esc}\][^${_bel}${_esc}]*${_bel}//g
    s/${_esc}\][^${_esc}]*${_esc}\\\\//g
    s/${_esc}\[[0-9;?]*[A-Za-z]//g
    s/${_esc}[78=>]//g
    s/${_cr}//g
  " "$1"
}

# Log a one-line diagnostic capturing the state at empty-output time, so the
# next real hook firing tells us whether the pty wrap helped or whether the
# problem is an OAuth/recursion conflict that only ANTHROPIC_API_KEY can fix.
# Keys logged: ec (claude exit code), out (stdout bytes), err (stderr first
# 80B), tty (which of stdin/stdout/stderr were ttys), cc (CLAUDECODE set?),
# ak (ANTHROPIC_API_KEY set?), pty (was the pty wrap attempted?).
sb_log_extractor_diag() {
  local script_name="$1" stage="$2" claude_ec="$3" out_bytes="$4" err_file="$5" pty_attempted="$6"
  local err_head
  err_head=$(head -c 80 "$err_file" 2>/dev/null | tr -d '\000-\037' | tr -s ' ' | head -c 80)
  local tty_state=""
  [ -t 0 ] && tty_state="${tty_state}i"
  [ -t 1 ] && tty_state="${tty_state}o"
  [ -t 2 ] && tty_state="${tty_state}e"
  [ -z "$tty_state" ] && tty_state="-"
  local cc="0" ak="0"
  [ -n "${CLAUDECODE:-}" ] && cc="1"
  [ -n "${ANTHROPIC_API_KEY:-}" ] && ak="1"
  sb_log_error "$script_name" \
    "extractor-diag stage=$stage ec=$claude_ec out=$out_bytes err=\"$err_head\" tty=$tty_state cc=$cc ak=$ak pty=$pty_attempted" 0
}

# Backend 0 helper: call a local OpenAI-compatible chat endpoint (ollama /v1).
# $1 url, $2 model, $3 system-prompt, $4 input-file, $5 out-file, $6 timeout.
# Returns 0 and writes a JSON object to $5 on success; 1 otherwise. No creds.
sb_extractor_local_call() {
  local url="$1" model="$2" prompt="$3" input_file="$4" out_file="$5" timeout_s="${6:-60}"
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
  # Input budgeting: a small CPU model (e.g. qwen2.5:3b on a Pi) cannot chew a
  # full multi-MB transcript — it overflows context and the run never finishes.
  # Send only the most-recent SB_EXTRACTOR_LOCAL_MAX_BYTES (default 6000) — recent
  # exchanges carry the session's decisions/plans. 0 disables the cap.
  local src="$input_file" capped="" maxb="${SB_EXTRACTOR_LOCAL_MAX_BYTES:-6000}"
  case "$maxb" in ''|*[!0-9]*) maxb=6000 ;; esac
  if [ "$maxb" -gt 0 ] && [ "$(wc -c < "$input_file" 2>/dev/null || echo 0)" -gt "$maxb" ]; then
    capped=$(mktemp) && tail -c "$maxb" "$input_file" > "$capped" && src="$capped"
  fi
  local payload
  payload=$(jq -n --arg m "$model" --arg s "$prompt" --rawfile u "$src" \
    '{model:$m, stream:false, messages:[{role:"system",content:$s},{role:"user",content:$u}]}' 2>/dev/null) || { [ -n "$capped" ] && rm -f "$capped"; return 1; }
  [ -n "$capped" ] && rm -f "$capped"
  [ -n "$payload" ] || return 1
  local TBIN resp
  TBIN=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
  resp=$( ${TBIN:+"$TBIN" "$timeout_s"} curl -sS "${url%/}/v1/chat/completions" \
    -H 'content-type: application/json' --data-binary @<(printf '%s' "$payload") 2>/dev/null ) || return 1
  local text
  text=$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null | tr -d '\r')
  [ -n "$text" ] || return 1
  # Validate in a staging temp and only mv into $out_file on a valid JSON OBJECT —
  # never leave non-object garbage in $out_file (a failed local in `auto` mode falls
  # through, and a downstream return-0 would otherwise ship the stale partial as a
  # "successful" extraction, defeating the degraded-breadcrumb fallback). Mirrors
  # the .clean staging the claude-cli / anthropic-api backends use.
  local tmp_out="${out_file}.local.$$"
  printf '%s' "$text" | sb_strip_code_fences > "$tmp_out"
  if jq -e 'type == "object"' "$tmp_out" >/dev/null 2>&1; then
    mv "$tmp_out" "$out_file"
    return 0
  fi
  rm -f "$tmp_out"
  return 1
}

sb_call_extractor() {
  local input_file="$1" out_file="$2" model="$3" prompt="$4" timeout_s="${5:-30}"
  local err_file caller_script
  err_file=$(mktemp)
  caller_script="${SB_SCRIPT_NAME:-${0##*/}}"

  # R1.1 nested-spawn containment: the headless child (a) inherits
  # SB_NESTED_SPAWN=1 so plugin hooks no-op inside it instead of re-running the
  # full SessionStart/Stop stack (~24s on a Pi — the cause of every ec=124
  # timeout), and (b) runs with cwd in a dedicated scratch dir so its junk
  # transcript lands in ONE prunable ~/.claude/projects entry.
  # NOTE: PreToolUse/PostToolUse/ConfigChange guards intentionally do NOT honor
  # SB_NESTED_SPAWN — tool-safety checks stay active inside headless children
  # (defense-in-depth); only capture/context hooks no-op.
  local scratch_dir="$BRAIN_DIR/scratch"
  if ! mkdir -p "$scratch_dir" 2>/dev/null; then
    sb_log_error "lib.sh" "scratch mkdir failed; nested-spawn transcripts will land in the cwd project entry: $PWD" 0
    scratch_dir="$PWD"
  fi

  # --- Backend 0: local LLM (OpenAI-compatible /v1) ------------------------
  # Tried FIRST when SB_EXTRACTOR_LOCAL_URL is set and the engine isn't pinned
  # to a remote backend. No recursive-claude lock (not claude), no Anthropic
  # creds -> works in-session AND offline. ENGINE=local pins it (no fallback).
  local _engine="${SB_EXTRACTOR_ENGINE:-auto}"
  if [ -n "${SB_EXTRACTOR_LOCAL_URL:-}" ] && [ "$_engine" != "cli" ] && [ "$_engine" != "bare" ]; then
    # Default 90s: give the local model a fair shot, but in `auto` mode fall through
    # to the Claude/API backend promptly when it can't deliver (e.g. a slow Pi CPU on
    # a big transcript). ENGINE=local users who want to wait longer raise this.
    if sb_extractor_local_call "$SB_EXTRACTOR_LOCAL_URL" \
         "${SB_EXTRACTOR_LOCAL_MODEL:-qwen2.5:3b}" "$prompt" "$input_file" "$out_file" \
         "${SB_EXTRACTOR_LOCAL_TIMEOUT:-90}"; then
      sb_write_extractor_health "local" "ok" ""
      rm -f "$err_file"; return 0
    fi
    if [ "$_engine" = "local" ]; then
      sb_write_extractor_health "local" "fail" "local endpoint ${SB_EXTRACTOR_LOCAL_URL} unreachable or non-JSON"
      rm -f "$err_file"; return 1
    fi
  fi

  # --- Backend pre-selection (recursive-claude guard) ----------------------
  # Stop / PreCompact hooks run inside a Claude Code session (CLAUDECODE=1),
  # and spawning `claude -p` from there re-enters the same OAuth-locked
  # process — it reliably hangs to the timeout. Two safe paths from here:
  #   (a) ANTHROPIC_API_KEY set → skip Backend 1 entirely, jump to curl.
  #       Avoids the wasted 40s timeout the CLI burns before we fall back.
  #   (b) only OAuth available → record health=queued and exit non-fatal so
  #       the SessionStart banner can surface the configuration accurately.
  #       Real-time extraction in this mode is structurally impossible.
  # Escape hatch: SB_FORCE_CLI=1 forces the legacy path (debugging only).
  local SB_SKIP_CLI=0
  if [ "${CLAUDECODE:-}" = "1" ] && [ "${SB_FORCE_CLI:-0}" != "1" ]; then
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
      sb_write_extractor_health "none" "queued" \
        "in-session OAuth only — recursive-claude would hang; set ANTHROPIC_API_KEY or run \`sb auth doctor\`"
      rm -f "$err_file" 2>/dev/null
      return 0
    fi
    SB_SKIP_CLI=1
  fi

  # --- Backend 1: claude CLI -----------------------------------------------
  # `--bare` is a perf optimization (skips hooks/LSP, saves ~10s) but per
  # `claude --help`: bare-mode auth is STRICTLY ANTHROPIC_API_KEY — OAuth
  # tokens from `claude /login` are never read. So we only use --bare when
  # an API key is present; otherwise we use the slower full path that
  # honors OAuth. Override with SB_USE_BARE=1 to force.
  #
  # SB_USE_BWRAP=1 (opt-in, v0.21.0 P2b): wrap the claude invocation in
  # bubblewrap so the extractor sees a read-only root with only
  # ~/.second-brain writable. Closes G-SANDBOX-1. Requires bwrap binary;
  # falls back to direct invocation if absent. Network stays enabled
  # (extractor needs the API).
  if [ "$SB_SKIP_CLI" != "1" ] && command -v claude >/dev/null 2>&1; then
    local -a CLI_ARGS=(-p --model "$model" --system-prompt "$prompt")
    if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ "${SB_USE_BARE:-0}" = "1" ]; then
      CLI_ARGS=(-p --bare --model "$model" --system-prompt "$prompt")
    fi
    local -a WRAP_PREFIX=()
    if [ "${SB_USE_BWRAP:-0}" = "1" ] && command -v bwrap >/dev/null 2>&1; then
      WRAP_PREFIX=(
        bwrap
        --ro-bind / /
        --bind "$HOME/.second-brain" "$HOME/.second-brain"
        --tmpfs /tmp
        --proc /proc
        --dev /dev
        --unshare-pid
        --new-session
        --die-with-parent
        --setenv HOME "$HOME"
        --setenv PATH "${PATH:-/usr/local/bin:/usr/bin:/bin}"
        --setenv ANTHROPIC_API_KEY "${ANTHROPIC_API_KEY:-}"
        --
      )
    elif [ "${SB_USE_BWRAP:-0}" = "1" ]; then
      # User asked for bwrap but binary missing — log once per call so the
      # health banner can surface this.
      sb_log_error "lib.sh" "SB_USE_BWRAP=1 but bwrap not found in PATH; falling back to direct invocation" 0
    fi
    local claude_ec=0
    local TBIN; TBIN=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)  # GNU || macOS-brew
    if [ -n "$TBIN" ]; then
      ( cd "$scratch_dir" && SB_NESTED_SPAWN=1 "$TBIN" "$timeout_s" ${WRAP_PREFIX[@]+"${WRAP_PREFIX[@]}"} claude "${CLI_ARGS[@]}" \
        < "$input_file" > "$out_file" 2>"$err_file" )
      claude_ec=$?
    else
      ( cd "$scratch_dir" && SB_NESTED_SPAWN=1 ${WRAP_PREFIX[@]+"${WRAP_PREFIX[@]}"} claude "${CLI_ARGS[@]}" \
        < "$input_file" > "$out_file" 2>"$err_file" )
      claude_ec=$?
    fi

    # Cheap auth-failure signature check on combined stdout+stderr tail.
    local combined
    combined=$(head -c 400 "$out_file" 2>/dev/null; head -c 400 "$err_file" 2>/dev/null)
    if echo "$combined" | grep -qiE '(not logged in|please run /login|unauthorized|invalid api key)'; then
      sb_write_extractor_health "claude-cli" "fail" \
        "auth: $(printf '%s' "$combined" | tr '\n' ' ' | head -c 120)"
    elif [ -s "$out_file" ]; then
      sb_strip_code_fences < "$out_file" > "${out_file}.clean" 2>/dev/null \
        && mv "${out_file}.clean" "$out_file"
      if jq -e 'type == "object"' "$out_file" >/dev/null 2>&1; then
        sb_write_extractor_health "claude-cli" "ok" ""
        rm -f "$err_file"
        return 0
      fi
      sb_write_extractor_health "claude-cli" "fail" \
        "non-json: $(head -c 100 "$out_file" | tr '\n' ' ')"
    else
      # --- Backend 1b: empty-output retry under pty wrap -----------------
      # claude -p inside a Claude Code hook subprocess sometimes returns 0
      # bytes (upstream anthropics/claude-code#38651, #38774, #9026, #7263).
      # In our local repro the same call from an interactive Bash succeeds
      # — the failure is specific to the hook-firing moment when the
      # parent process is mid-compact / mid-stop. A pty-allocated retry via
      # script(1) helps in some non-TTY contexts (see [[router-daemon]] and
      # [[pty-openpty-privatedevices-quirk]] for prior art). If the pty
      # retry also returns empty, the diagnostic line we log here gives the
      # ground truth for the *next* failure cycle.
      local pty_tried="no"
      sb_log_extractor_diag "$caller_script" "direct" "$claude_ec" \
        "$(wc -c < "$out_file" | tr -d ' ')" "$err_file" "$pty_tried"
      if [ "${SB_PTY_RETRY:-on}" != "off" ] && command -v script >/dev/null 2>&1; then
        pty_tried="yes"
        : > "$out_file"; : > "$err_file"
        local -a CLI_ARGS_QUOTED=()
        for arg in "${CLI_ARGS[@]}"; do
          CLI_ARGS_QUOTED+=("$(printf '%q' "$arg")")
        done
        local inner="claude ${CLI_ARGS_QUOTED[*]} < $(printf '%q' "$input_file") > $(printf '%q' "$out_file") 2> $(printf '%q' "$err_file")"
        local TBIN2; TBIN2=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
        if [ -n "$TBIN2" ]; then
          inner="$TBIN2 $timeout_s $inner"
        fi
        # script -qfc syntax is util-linux specific; we already require Linux
        # for the rest of the plugin so no portability shim here.
        # Wrap the inner command in `bash -c` explicitly: script(1) invokes
        # its -c arg via $SHELL, and `printf %q` produces bash-specific
        # $'...' C-string escapes that other shells (dash) do not parse,
        # which would silently corrupt the 5KB system prompt.
        local pty_raw
        pty_raw=$(mktemp)
        ( cd "$scratch_dir" && SB_NESTED_SPAWN=1 script -qfc "bash -c $(printf '%q' "$inner")" /dev/null > "$pty_raw" 2>/dev/null </dev/null ) || true
        rm -f "$pty_raw"
        if [ -s "$out_file" ]; then
          # Strip ANSI/VT sequences from claude's stdout (the pty echoes them
          # back when allocated).
          sb_strip_ansi "$out_file" > "${out_file}.clean" 2>/dev/null \
            && mv "${out_file}.clean" "$out_file"
          sb_strip_code_fences < "$out_file" > "${out_file}.clean" 2>/dev/null \
            && mv "${out_file}.clean" "$out_file"
          if jq -e 'type == "object"' "$out_file" >/dev/null 2>&1; then
            sb_write_extractor_health "claude-cli" "ok" "pty-retry"
            rm -f "$err_file"
            return 0
          fi
          sb_write_extractor_health "claude-cli" "fail" \
            "pty-retry-non-json: $(head -c 100 "$out_file" | tr '\n' ' ')"
        else
          # Both direct and pty-wrapped came back empty. The most likely
          # remaining cause is recursive-claude / OAuth-state conflict (parent
          # Claude Code holds the OAuth token mid-API-call). Recommend the
          # ANTHROPIC_API_KEY backstop, which uses a distinct credential path.
          if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
            sb_write_extractor_health "claude-cli" "fail" \
              "empty after pty-retry (recursive-claude conflict suspected) — set ANTHROPIC_API_KEY for direct-API backstop"
          else
            sb_write_extractor_health "claude-cli" "fail" \
              "empty after pty-retry — falling back to anthropic-api"
          fi
          sb_log_extractor_diag "$caller_script" "pty" "$claude_ec" \
            "$(wc -c < "$out_file" | tr -d ' ')" "$err_file" "$pty_tried"
        fi
      else
        sb_write_extractor_health "claude-cli" "fail" \
          "empty output: $(head -c 100 "$err_file" | tr '\n' ' ')"
      fi
    fi
    : > "$out_file"   # reset before fallback attempt
  fi

  # --- Backend 2: ANTHROPIC_API_KEY via curl -------------------------------
  if [ -n "${ANTHROPIC_API_KEY:-}" ] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    local payload
    payload=$(jq -n \
      --arg m "$model" \
      --arg s "$prompt" \
      --rawfile u "$input_file" \
      '{model:$m, max_tokens:4096, system:$s, messages:[{role:"user", content:$u}]}' 2>/dev/null)

    if [ -n "$payload" ]; then
      local resp
      # Honor ANTHROPIC_BASE_URL for enterprise gateways / proxies / air-gapped
      # Anthropic-compatible endpoints; default to the public host.
      # </dev/null: curl takes the payload via process substitution and never
      # needs stdin — but WITHOUT closing it, any stdin-reading stand-in (test
      # stub, gateway wrapper) inherits the caller's stdin and blocks until the
      # timeout kills it whenever that stdin never EOFs (e.g. a background
      # runner's open pipe — the in-suite-only test-lib-extractor-backend hang).
      resp=$(timeout "$timeout_s" curl -sS "${ANTHROPIC_BASE_URL:-https://api.anthropic.com}/v1/messages" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        --data-binary @<(printf '%s' "$payload") </dev/null 2>"$err_file" || true)

      local text
      text=$(printf '%s' "$resp" | jq -r '.content[0].text // empty' 2>/dev/null | tr -d '\r')

      if [ -n "$text" ]; then
        printf '%s' "$text" | sb_strip_code_fences > "$out_file"
        if jq -e 'type == "object"' "$out_file" >/dev/null 2>&1; then
          sb_write_extractor_health "anthropic-api" "ok" ""
          rm -f "$err_file"
          return 0
        fi
        sb_write_extractor_health "anthropic-api" "fail" \
          "non-json: $(head -c 100 "$out_file" | tr '\n' ' ')"
      else
        local api_err
        api_err=$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null | tr -d '\r')
        sb_write_extractor_health "anthropic-api" "fail" \
          "api: ${api_err:-no response}"
      fi
    fi
  elif [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    # Only overwrite to "none" if no claude CLI attempt fired (otherwise the
    # CLI failure reason is more actionable).
    [ -x "$(command -v claude 2>/dev/null)" ] || \
      sb_write_extractor_health "none" "fail" "no claude CLI and ANTHROPIC_API_KEY not set"
  fi

  rm -f "$err_file"
  return 1
}

# Read current extractor health. Echoes JSON, or '{}' if no marker.
sb_get_extractor_health() {
  [ -f "$SB_HEALTH_FILE" ] && cat "$SB_HEALTH_FILE" || echo '{}'
}

# Count consecutive recent extraction failures from error-log.jsonl.
# Echoes an integer. Used by session-load.sh to decide banner severity.
sb_count_recent_extraction_failures() {
  local log="$BRAIN_DIR/error-log.jsonl"
  [ -f "$log" ] || { echo 0; return; }
  # last 20 entries from extractor scripts, count llm-extraction-failed
  tail -20 "$log" 2>/dev/null \
    | jq -r 'select(.script == "stop-extract.sh" or .script == "pre-compact.sh") | .message' 2>/dev/null \
    | grep -c 'llm-extraction-failed' 2>/dev/null || true
}

# Verify jq is available. If missing, log to error-log.jsonl and return 1.
# Caller pattern: `sb_require_jq || exit 0` — the hook then exits cleanly
# rather than running jq commands that would silently no-op. The error is
# surfaced to the user at next SessionStart via the error-nudge banner.
# Cached per-process via SB_JQ_OK to avoid repeated PATH lookups.
sb_require_jq() {
  if [ -n "${SB_JQ_OK:-}" ]; then
    [ "$SB_JQ_OK" = "1" ] && return 0 || return 1
  fi
  if command -v jq >/dev/null 2>&1; then
    SB_JQ_OK=1
    return 0
  fi
  SB_JQ_OK=0
  local caller="${SB_SCRIPT_NAME:-${0##*/}}"
  sb_log_error "$caller" "jq not on PATH — hook no-op'd. Install: brew install jq / apt install jq / winget install jqlang.jq" 127
  return 1
}

# --- Out-of-band extraction helpers (v0.13.0) ----------------------------
# A transcript is "done" once a terminal (ok|error) line exists in the
# append-only done-set ~/.second-brain/.extraction-state.jsonl.
sb_extraction_done() {
  local base="$1" state="$2"
  [ -f "$state" ] || return 1
  local hit
  # -R + fromjson? : parse per line, skipping any corrupt line (e.g. a partial
  # append from a crash) instead of aborting the whole scan.
  hit=$(jq -rR --arg b "$base" \
    'fromjson? | select(.basename == $b and (.outcome == "ok" or .outcome == "error")) | .basename' \
    "$state" 2>/dev/null | head -1)
  [ -n "$hit" ]
}

# Count prior non-terminal retry attempts for a basename.
sb_extraction_fails() {
  local base="$1" state="$2"
  [ -f "$state" ] || { echo 0; return; }
  jq -rR --arg b "$base" 'fromjson? | select(.basename == $b and .outcome == "retry") | .basename' \
    "$state" 2>/dev/null | wc -l | tr -d ' '
}

# Read project_slug: from the archived transcript's meta header.
sb_slug_from_archived_transcript() {
  local txt="$1"
  [ -f "$txt" ] || return 1
  awk -F': ' '/^project_slug:/ {print $2; exit}' "$txt" 2>/dev/null | tr -d '\r'
}

# Build the extractor input from a preprocessed archived transcript + PROJECT.md,
# call the extractor, quality-gate the delta, merge it, route persona signals.
# Returns 0 only on a successful merge. Used by the out-of-band drainer.
sb_extract_transcript() {
  local txt="$1" slug="$2"
  [ -f "$txt" ] || return 1
  # Sanitize the slug before it becomes a filesystem path: the drainer reads it
  # from the transcript's meta header, which is attacker-influenceable (synced /
  # restored / foreign-written transcripts dir). Without this, a header like
  # `project_slug: ../../../tmp/x` would escape BRAIN_DIR. Same control the merge
  # path already applies to JSON-sourced slugs.
  slug=$(sb_sanitize_slug "$slug") || slug="unknown"
  local sdir; sdir="$(dirname "${BASH_SOURCE[0]}")"
  local model="${SB_EXTRACTOR_MODEL:-claude-sonnet-4-6}"
  # Drainer-specific knob (deep-review): the hooks share SB_EXTRACT_TIMEOUT with
  # small defaults (25s/30s inside 45s hook budgets) — reusing it here would let a
  # drainer-oriented override re-open the kill-after-extract window in-hook.
  #
  # Default 240s (Phase 1.2, slow-HW headroom): a Pi-class box pays ~24s on the
  # nested-spawn hook stack before the extractor even starts, so a real extraction
  # over the 200KB tail cap can blow the old 120s budget -> ec=124 -> retry; 3
  # outcomes (SB_DRAIN_MAX_FAILS) terminally mark the transcript `error`. 240s
  # doubles the per-attempt budget. BUDGET PROOF it stays well under the 7200s lock
  # steal-threshold (SB_DRAIN_LOCK_STALE) even fully degraded: worst case per
  # transcript = 3 retry paths (direct + pty + API) x timeout_s, x SB_DRAIN_BATCH=5
  #   = 5 x 3 x 240 = 3600s = HALF of 7200 — a live run can't be judged stale and
  # have its lock stolen. 240 is the LARGEST value keeping BATCH x 3 x timeout_s
  # <= 7200/2; do NOT raise further without also raising SB_DRAIN_LOCK_STALE.
  local timeout_s="${SB_DRAIN_EXTRACT_TIMEOUT:-240}"
  local prompt_file="$sdir/extract-prompt.txt"
  [ -f "$prompt_file" ] || return 1
  local prompt; prompt=$(cat "$prompt_file")

  local kdir="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"; kdir="${kdir/#\~/$HOME}"
  local project_md="$BRAIN_DIR/projects/$slug/PROJECT.md"
  if [ ! -f "$project_md" ]; then
    mkdir -p "$(dirname "$project_md")"
    cat > "$project_md" <<TMPL
# PROJECT: $slug

## Goal
(auto-scaffolded — describe this project's goal)

## State

## Plan

## Conventions

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: $(date -u +%Y-%m-%dT%H:%M:%SZ) -->
<!-- last_queried_wiki: -->
TMPL
  fi
  mkdir -p "$kdir/wiki" 2>/dev/null || true

  local in_f out_f; in_f=$(mktemp); out_f=$(mktemp)
  {
    echo "=== PROJECT.md ==="
    cat "$project_md"
    echo; echo "---SEPARATOR---"; echo
    echo "=== TRANSCRIPT (preprocessed) ==="
    # Body only (meta header dropped), tail-capped: keep the NEWEST exchanges.
    # An uncapped multi-MB archive can never finish before the timeout on a Pi
    # and burns full retry cycles toward quarantine (R1.2, HOOK-4).
    # tr -d '\r' FIRST: a CRLF archive's header is `---\r`, which `/^---$/` never matches —
    # then `1,/re/d` (no terminator hit) deletes the WHOLE transcript, starving the extractor.
    tr -d '\r' < "$txt" | sed '1,/^---$/d' | tail -c "${SB_EXTRACT_MAX_BYTES:-200000}"
  } > "$in_f"

  local delta=""
  if sb_call_extractor "$in_f" "$out_f" "$model" "$prompt" "$timeout_s"; then
    delta=$(cat "$out_f")
  fi
  rm -f "$in_f" "$out_f"
  [ -n "$delta" ] || return 1

  local gated; gated=$(printf '%s' "$delta" | bash "$sdir/extraction-quality-gate.sh" 2>/dev/null)
  if [ -n "$gated" ] && printf '%s' "$gated" | jq empty 2>/dev/null; then delta="$gated"; fi

  printf '%s' "$delta" \
    | bash "$sdir/merge-project-update.sh" --project-md "$project_md" --knowledge-dir "$kdir" \
      >/dev/null 2>&1 || return 1

  local sigs; sigs=$(printf '%s' "$delta" | jq -c '.persona_signals // []' 2>/dev/null)
  if [ -n "$sigs" ] && printf '%s' "$sigs" | jq -e 'length > 0' >/dev/null 2>&1; then
    printf '%s' "$sigs" | bash "$sdir/merge-persona-signals.sh" 2>/dev/null || true
  fi
  return 0
}

# Detect Claude Code's built-in auto-memory state. Pure-bash, offline, fail-soft
# (never errors out; defaults to "on" rather than non-zero). Emits key=value
# lines on stdout: state, reason, path, files, memory_lines. Consumed by the
# status + audit skills to surface the native store alongside the second-brain.
# See docs/specs/2026-05-29-auto-memory-coordination-design.md.
#
# State precedence (mirrors CC's own resolution; disable is OR across layers so
# we only claim "on" when nothing anywhere disables it):
#   1. CLAUDE_CODE_DISABLE_AUTO_MEMORY=1                          -> off / env-disabled
#   2. autoMemoryEnabled:false in project OR user settings.json  -> off / setting-disabled
#   3. otherwise                                                 -> on  / default-on
# --- config.json reader (SP-B) -----------------------------------------------
# A persistent ~/.second-brain/config.json supplies defaults for knobs that are
# otherwise env-only. PRECEDENCE: an explicit SB_* env var ALWAYS wins; config.json
# is the persistent default when the env is unset; a hard-coded default is the final
# fallback when the file/key is absent — so today's behaviour is byte-for-byte
# preserved when no config.json exists. Pattern: "${SB_FOO:-$(sb_config_get .foo HARD)}".
# tr -d '\r' on EVERY jq read: the Windows (Git-Bash) jq build emits CRLF in -r output, so
# without this an `auto_improve: true` reads back as "true\r" — sb_config_bool's case then
# falls through to the default and the WHOLE config system (every automation knob) silently
# mis-reads on Windows. One strip here fixes every config consumer.
sb_config_get() {  # $1=jq-path  $2=default  → string value or default
  local cf="${BRAIN_DIR:-$HOME/.second-brain}/config.json"
  [ -f "$cf" ] || { printf '%s' "$2"; return 0; }
  local v; v=$(jq -r "$1 // empty" "$cf" 2>/dev/null | tr -d '\r')
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"
}
sb_config_bool() {  # $1=jq-path  $2=default(on|off)
  # Raw read (NO jq `//`) so an explicit `false` is honoured as OFF, not treated as
  # absent — the trap _sb_am_bool documents below. Distinguish the three cases:
  #   true → on   ·   false → off   ·   null/absent/malformed → the default.
  local cf="${BRAIN_DIR:-$HOME/.second-brain}/config.json"
  [ -f "$cf" ] || { printf '%s' "$2"; return 0; }
  local v; v=$(jq -r "$1" "$cf" 2>/dev/null | tr -d '\r')
  case "$v" in
    true)  printf 'on' ;;
    false) printf 'off' ;;
    *)     printf '%s' "$2" ;;
  esac
}

sb_auto_memory_state() {
  local home="${HOME:-/root}"
  local proj_settings="$PWD/.claude/settings.json"
  local user_settings="$home/.claude/settings.json"

  # Boolean read: do NOT use `// empty` — jq's `//` treats `false` (not just
  # null) as absent and would drop the very disable signal we need. Read the
  # raw value; prints "false"/"true"/"null", or "" on missing/malformed file.
  _sb_am_bool() {  # $1=file $2=jq-path
    [ -f "$1" ] || return 0
    jq -r "$2" "$1" 2>/dev/null || true
  }
  # String read: `// empty` is correct here (a string value or absent).
  _sb_am_str() {   # $1=file $2=jq-path
    [ -f "$1" ] || return 0
    jq -r "$2 // empty" "$1" 2>/dev/null || true
  }

  local state reason
  if [ "${CLAUDE_CODE_DISABLE_AUTO_MEMORY:-}" = "1" ]; then
    state=off; reason=env-disabled
  else
    local proj_v user_v
    proj_v=$(_sb_am_bool "$proj_settings" '.autoMemoryEnabled')
    user_v=$(_sb_am_bool "$user_settings" '.autoMemoryEnabled')
    if [ "$proj_v" = "false" ] || [ "$user_v" = "false" ]; then
      state=off; reason=setting-disabled
    else
      state=on; reason=default-on
    fi
  fi

  # path: user-settings autoMemoryDirectory wins (absolute or ~/-prefixed only),
  # else default ~/.claude/projects/<dashed-project-key>/memory. The <project-key>
  # is the GIT ROOT (Claude Code shares one auto-memory store per repo across
  # worktrees/subdirs); outside a git repo, fall back to cwd — matching CC docs.
  local custom_dir path=""
  custom_dir=$(_sb_am_str "$user_settings" '.autoMemoryDirectory')
  if [ -n "$custom_dir" ]; then
    case "$custom_dir" in
      "~/"*) path="$home/${custom_dir#\~/}" ;;
      /*)    path="$custom_dir" ;;
      *)     path="" ;;  # neither absolute nor ~/ — ignore, use default
    esac
  fi
  if [ -z "$path" ]; then
    local project_root dashed
    project_root=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)
    [ -z "$project_root" ] && project_root="$PWD"   # outside a git repo: use cwd
    dashed=$(printf '%s' "$project_root" | sed 's#/#-#g')
    path="$home/.claude/projects/$dashed/memory"
  fi

  # SECURITY: autoMemoryDirectory comes from settings.json — a trust boundary.
  # A value carrying a newline or shell metacharacter would, once this output is
  # consumed, smuggle extra key=value lines or inject shell (the adversarial-review
  # finding). A real memory dir contains only path-safe characters, so if the
  # resolved path has anything outside [space / A-Za-z0-9 . _ ~ -] (this set
  # includes newline and every shell metacharacter by exclusion), reject it and
  # fall back to the safe default. (Consumers also no longer eval — defense in depth.)
  case "$path" in
    *[!\ /A-Za-z0-9._~-]*)
      local project_root dashed
      project_root=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)
      [ -z "$project_root" ] && project_root="$PWD"
      dashed=$(printf '%s' "$project_root" | sed 's#/#-#g')
      path="$home/.claude/projects/$dashed/memory"
      ;;
  esac

  # size: .md file count + MEMORY.md line count (0 when the store doesn't exist yet).
  local files=0 memory_lines=0
  if [ -d "$path" ]; then
    files=$(find "$path" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
    [ -f "$path/MEMORY.md" ] && memory_lines=$(wc -l < "$path/MEMORY.md" 2>/dev/null | tr -d ' ')
  fi

  printf 'state=%s\nreason=%s\npath=%s\nfiles=%s\nmemory_lines=%s\n' \
    "$state" "$reason" "$path" "${files:-0}" "${memory_lines:-0}"
  return 0
}
