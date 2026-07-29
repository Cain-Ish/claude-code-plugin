#!/bin/bash
# Shared functions for second-brain hook scripts.
# Source this at the top of any hook script: source "$(dirname "$0")/lib.sh"

BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
# Windows (git-bash): an inherited BRAIN_DIR from the Node MCP arrives in Windows form (C:\Users\...).
# GNU tar/rsync read a leading drive letter as a remote host:path ("Cannot connect to C:") and `ln -s`
# mis-links it — the dream_accept bug class (0.33.10). Normalize to MSYS form (/c/...) ONCE here, at the
# inheritance boundary every script sources, so every current + future tar/rsync/ln sink is safe by
# construction. cygpath exists only under git-bash/Cygwin; on POSIX it's absent and this is a no-op (real
# Linux/macOS paths have no drive letter). Idempotent: cygpath -u on an already-MSYS path returns it as-is.
command -v cygpath >/dev/null 2>&1 && BRAIN_DIR=$(cygpath -u "$BRAIN_DIR" 2>/dev/null || printf '%s' "$BRAIN_DIR")

# SB_HOOK_PROFILE=minimal — one lever that collapses the hook surface to essentials.
# Maps onto the EXISTING kill switches (individually-set values always win; ${VAR:-}
# preserves any explicit setting). Essentials that stay on: guards, extraction,
# session-load. Everything advisory/cosmetic goes quiet.
# Split contract: this block only covers flags read AFTER lib.sh is sourced.
# Kill-switch checks that run pre-source or in lib-less scripts carry their own
# one-line SB_HOOK_PROFILE shim at the check site; the pairing is machine-locked
# in mcp/src/prose-locks.test.ts.
if [ "${SB_HOOK_PROFILE:-}" = "minimal" ]; then
  : "${SB_SAR_SUMMARY:=off}" "${SB_PLAN_FIRST_NUDGE:=off}" "${SB_DREAM_AUTOSTAGE:=off}" \
    "${SB_CRITIC_OFFER:=off}" "${SB_LOOP_DEAD_BANNER:=off}" "${SB_CODEMAP_ORIENT:=off}" \
    "${SB_INJECTION_SCAN:=off}" "${SB_CONFIG_CHANGE_AUDIT:=off}" "${SB_INTENT_SPINE:=off}"
  export SB_SAR_SUMMARY SB_PLAN_FIRST_NUDGE SB_DREAM_AUTOSTAGE SB_CRITIC_OFFER \
    SB_LOOP_DEAD_BANNER SB_CODEMAP_ORIENT SB_INJECTION_SCAN SB_CONFIG_CHANGE_AUDIT SB_INTENT_SPINE
fi

# sb_normalize_path — canonicalize a path STRING to the plugin's POSIX form so
# the PreToolUse guards compare like-with-like. On Windows git-bash a hook
# payload's file_path arrives as 'C:\Users\…' (or 'C:/Users/…') while $HOME —
# and every credential/scope prefix derived from it — is '/c/Users/…'. That
# form mismatch silently fail-OPENED symlink-guard / persona-tool-guard /
# wiki-write-guard (all three inert on Windows, the platform this plugin is
# developed on). This is the one funnel every guard runs its paths through,
# mirroring the brain-paths.ts homedir() funnel on the TS side. Two lexical,
# idempotent, symlink-free steps:
#   1. backslash -> forward slash (Claude Code never uses '\' as a Unix separator)
#   2. drive-letter absolute (C:/…) -> cygpath -u POSIX form (/c/…) when cygpath
#      exists (git-bash/Cygwin); a no-op on Linux/macOS (no drive letter, no cygpath)
# Prints the normalized path; empty in -> empty out. Callers that must resolve
# symlinks realpath FIRST, then normalize the result (realpath emits C:/ form on
# Windows, so its OUTPUT is what needs normalizing).
sb_normalize_path() {
  local p="$1" u d
  [ -z "$p" ] && return 0
  p="${p//\\//}"
  # Windows extended-length prefix \\?\C:\… (→ //?/C:/… after slashing): strip
  # to the plain drive form so it can't sail past the drive-letter case below.
  p="${p#"//?/"}"
  # Loopback admin-share UNC (\\localhost\c$\…, \\127.0.0.1\c$\…) is the same
  # local drive in disguise — rewrite to drive form. Other-host UNC paths are
  # not locally resolvable and pass through unchanged (documented limit).
  case "$p" in
    //localhost/[A-Za-z]\$/*)  d="${p#//localhost/}";  d="${d%%\$*}"; p="$d:${p#//localhost/[A-Za-z]\$}" ;;
    //127.0.0.1/[A-Za-z]\$/*)  d="${p#//127.0.0.1/}";  d="${d%%\$*}"; p="$d:${p#//127.0.0.1/[A-Za-z]\$}" ;;
  esac
  case "$p" in
    [A-Za-z]:/*)
      if command -v cygpath >/dev/null 2>&1; then
        u=$(cygpath -u "$p" 2>/dev/null) && [ -n "$u" ] && p="$u"
      fi
      ;;
  esac
  printf '%s' "$p"
}

# sb_mtime — portable file mtime as epoch seconds via `stat -c %Y` || `stat -f %m`
# || 0. THE single funnel for the ~17 copy-pasted GNU/BSD stat sites (portability
# floor: any line using the GNU form needs its BSD twin, which this one-liner has).
# Callers needing a NON-zero fail default (e.g. an unstattable file read as
# just-touched → echo "$now") keep their own inline form; sb_mtime yields 0 on
# failure, i.e. fail-CLOSED for age checks.
sb_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# sb_knowledge_dir — THE single resolver for the bash-side KNOWLEDGE_DIR, mirroring
# mcp/src/brain-paths.ts precedence: plugin OPTION > KNOWLEDGE_DIR env > $HOME/knowledge,
# with leading-~ expansion. Replaces the 4 divergent hand-rolled precedence variants
# that had accreted across ~38 sites. Sites that resolve BEFORE sourcing lib.sh, take a
# --knowledge-dir arg, or honor an extra alias (SB_KNOWLEDGE_DIR) keep their own form.
sb_knowledge_dir() {
  local d="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}"
  printf '%s' "${d/#\~/$HOME}"
}

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

# Deterministic, no-LLM extraction floor (P1 Task 1). Given a transcript and a line window,
# emit a VALID delta JSON the merge pipeline accepts — derived purely from the structured
# transcript, never an LLM. It captures the files this window changed (Edit/Write/MultiEdit,
# scratch paths excluded, capped) plus ONE grounded summary decision that cites those files.
# Deliberately NOT a per-message dump: a decision is emitted only when real files changed, so
# the floor stays signal, not trash (Constitution: "must guide a future decision"). Exits 0.
#   sb_extract_deterministic <transcript> <start_line> <total_line>
sb_extract_deterministic() {
  local transcript="$1" start="$2" total="$3"
  local files_json
  files_json=$(sed -n "${start},${total}p" "$transcript" 2>/dev/null | jq -rcs '
    [ .[]
      | select(.type == "assistant")
      | .message.content[]?
      | select(.type == "tool_use")
      | select(.name == "Edit" or .name == "Write" or .name == "MultiEdit")
      | .input.file_path ]
    | unique
    | map(select(. != null and . != ""))
    | map(gsub("\\\\"; "/"))
    | map(select(test("^/tmp/|^/var/tmp/|^/proc/|^/dev/|^/run/") | not))
    | .[0:5]
  ' 2>/dev/null || echo '[]')
  files_json=$(sb_safe_json_array "$files_json")
  local decisions='[]'
  if [ "$(printf '%s' "$files_json" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
    local list
    list=$(printf '%s' "$files_json" | jq -r 'join(", ")' 2>/dev/null)
    decisions=$(jq -cn --arg t "[auto-captured] Session changed: ${list} (LLM extraction unavailable; full context in the archived transcript)" '[$t]')
  fi
  jq -cn --argjson d "$decisions" --argjson f "$files_json" \
    '{recent_decisions:$d, open_blockers:[], cross_refs:[], files_touched:$f, relations:[]}'
}

# Text-format twin of sb_extract_deterministic for the OUT-OF-BAND drainer (P1). The ARCHIVED
# transcript body is PREPROCESSED TEXT (sb_preprocess_transcript renders tool calls as
# "  [Edit] <path>" / "  [Write] <path>" lines), NOT raw JSONL — so this harvests the
# Edit/Write/MultiEdit file paths from those lines (Read excluded: not a mutation), drops scratch
# paths, dedups, caps at 5, and emits ONE grounded decision citing them. Same delta shape the merge
# accepts. Emits an empty-but-valid delta when the transcript changed no files. Exits 0.
#   sb_extract_archived_deterministic <archived_transcript>
sb_extract_archived_deterministic() {
  local txt="$1"
  local files_json='[]'
  if [ -f "$txt" ]; then
    files_json=$(tr -d '\r' < "$txt" \
      | grep -E '^[[:space:]]*\[(Edit|Write|MultiEdit)\] ' \
      | sed -E 's/^[[:space:]]*\[(Edit|Write|MultiEdit)\] //' \
      | sed 's#\\#/#g' \
      | grep -vE '^/tmp/|^/var/tmp/|^/proc/|^/dev/|^/run/' \
      | awk 'NF && !seen[$0]++' \
      | head -5 \
      | jq -Rsc 'split("\n") | map(select(. != ""))' 2>/dev/null || echo '[]')
  fi
  files_json=$(sb_safe_json_array "$files_json")
  local decisions='[]'
  if [ "$(printf '%s' "$files_json" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
    local list; list=$(printf '%s' "$files_json" | jq -r 'join(", ")' 2>/dev/null)
    decisions=$(jq -cn --arg t "[auto-captured] Session changed: ${list} (LLM extraction unavailable; full context in the archived transcript)" '[$t]')
  fi
  jq -cn --argjson d "$decisions" --argjson f "$files_json" \
    '{recent_decisions:$d, open_blockers:[], cross_refs:[], files_touched:$f, relations:[]}'
}

# Last-resort deterministic floor for the out-of-band drainer (P1). When the LLM backend has failed
# MAX_FAILS times, capture the files-changed baseline from the archived transcript (no LLM) and merge
# it into PROJECT.md — so the autonomous path NEVER quarantines a code-changing session with zero
# capture. Returns 0 ONLY when a non-empty delta actually merged; 1 when the transcript had no
# extractable file change (caller then quarantines as 'error', preserving honest "couldn't capture"
# state rather than masking it as success).
#   sb_floor_transcript <archived_transcript> <slug>
sb_floor_transcript() {
  local txt="$1" slug="$2"
  [ -f "$txt" ] || return 1
  slug=$(sb_sanitize_slug "$slug") || slug="unknown"
  local delta; delta=$(sb_extract_archived_deterministic "$txt")
  [ -n "$delta" ] || return 1
  local nfiles; nfiles=$(printf '%s' "$delta" | jq '.files_touched | length' 2>/dev/null || echo 0)
  [ "${nfiles:-0}" -gt 0 ] || return 1   # nothing changed deterministically → let the caller quarantine
  local sdir; sdir="$(dirname "${BASH_SOURCE[0]}")"
  local project_md="$BRAIN_DIR/projects/$slug/PROJECT.md"
  local kdir; kdir="$(sb_knowledge_dir)"
  if [ ! -f "$project_md" ]; then
    mkdir -p "$(dirname "$project_md")"
    printf '# PROJECT: %s\n\n## Recent decisions\n\n## Open blockers\n\n## Cross-references\n\n<!-- last_updated: %s -->\n' \
      "$slug" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$project_md"
  fi
  local gated; gated=$(printf '%s' "$delta" | bash "$sdir/extraction-quality-gate.sh" 2>/dev/null)
  if [ -n "$gated" ] && printf '%s' "$gated" | jq empty 2>/dev/null; then delta="$gated"; fi
  printf '%s' "$delta" \
    | bash "$sdir/merge-project-update.sh" --project-md "$project_md" --knowledge-dir "$kdir" >/dev/null 2>&1
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

# --- Model resolution -----------------------------------------------------
# Every model reference in the plugin is a TIER INTENT resolved here, never a literal. Two
# surfaces exist and must never share a verdict: `headless` (claude -p spawns, accepts full IDs)
# and `dispatch` (Agent tool, alias-only schema enum). Alias->model mapping provably diverges
# between them in the same environment on the same day, because a running session keeps its
# startup-era harness mapping. The ladder itself lives in model-ladder.json so a newly released
# model is picked up by the alias rung with no code change.

sb_model_manifest() {
  if [ -n "${SB_MODEL_LADDER:-}" ]; then printf '%s\n' "$SB_MODEL_LADDER"; return 0; fi
  printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/model-ladder.json"
}

sb_model_auth_fingerprint() {
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then printf 'apikey\n'; else printf 'oauth\n'; fi
}

sb_model_cache_file() { printf '%s\n' "$BRAIN_DIR/model-availability.json"; }

# Prints ok | blocked | unknown. Always exits 0 — an unreadable cache is `unknown`, never fatal.
sb_model_cache_get() {
  local surface="${1:-headless}" model="${2:-}" f ttl now at state fp
  [ -n "$model" ] || { printf 'unknown\n'; return 0; }
  f=$(sb_model_cache_file)
  [ -f "$f" ] || { printf 'unknown\n'; return 0; }
  # A credential change means a different allowlist — every prior verdict is void.
  fp=$(jq -r '.auth_fingerprint // ""' "$f" 2>/dev/null | tr -d '\r')
  [ "$fp" = "$(sb_model_auth_fingerprint)" ] || { printf 'unknown\n'; return 0; }
  state=$(jq -r --arg s "$surface" --arg m "$model" \
            '.surfaces[$s][$m].state // "unknown"' "$f" 2>/dev/null | tr -d '\r')
  case "$state" in ok|blocked) ;; *) printf 'unknown\n'; return 0 ;; esac
  # Integer epoch, not an ISO string: `date -d` is GNU-only and this runs on BSD/macOS too.
  at=$(jq -r --arg s "$surface" --arg m "$model" \
         '.surfaces[$s][$m].epoch // 0' "$f" 2>/dev/null | tr -d '\r')
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  ttl="${SB_MODEL_CACHE_TTL:-604800}"; case "$ttl" in ''|*[!0-9]*) ttl=604800 ;; esac
  now=$(date -u +%s)
  if [ "$at" -gt 0 ] && [ $(( now - at )) -ge "$ttl" ]; then printf 'unknown\n'; return 0; fi
  printf '%s\n' "$state"
}

sb_model_cache_put() {
  local surface="${1:-headless}" model="${2:-}" state="${3:-blocked}"
  local reason="${4:-}" resolved="${5:-}"
  [ -n "$model" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local f tmp fp now iso base
  f=$(sb_model_cache_file)
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  fp=$(sb_model_auth_fingerprint); now=$(date -u +%s); iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  tmp=$(mktemp) || return 1
  base="$tmp.base"
  if [ -f "$f" ] && [ "$(jq -r '.auth_fingerprint // ""' "$f" 2>/dev/null | tr -d '\r')" = "$fp" ]; then
    cat "$f" > "$base" 2>/dev/null || printf '{}' > "$base"
  else
    printf '{"schema":1,"auth_fingerprint":"%s","surfaces":{}}' "$fp" > "$base"
  fi
  # setpath creates the intermediate objects; avoids the fragile nested-assign jq pipeline.
  if jq --arg fp "$fp" --arg s "$surface" --arg m "$model" --arg st "$state" \
        --arg r "$reason" --arg rv "$resolved" --arg iso "$iso" --argjson e "$now" \
        '.schema = 1 | .auth_fingerprint = $fp
         | setpath(["surfaces",$s,$m];
             {state:$st, reason:$r, at:$iso, epoch:$e}
             + (if $rv == "" then {} else {resolved:$rv} end))' \
        "$base" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" "$base" 2>/dev/null; return 1; }
    rm -f "$base" 2>/dev/null
    return 0
  fi
  rm -f "$tmp" "$base" 2>/dev/null
  sb_log_error "lib.sh" "model-availability write failed for $surface/$model" 1
  return 1
}

# Prints the first model on <tier>'s ladder that is not cached `blocked`. Operator pins declared
# in the manifest become rung 0 — honored, but still demotable: silently ignoring a pin would be
# the silent-fallback failure this repo bans, while refusing to demote would strand an operator
# whose admin blocked the model they pinned. Never prints an empty string: a wrong model that
# errors loudly beats a malformed spawn with no --model value.
sb_resolve_model() {
  local tier="${1:-mid}" surface="${2:-headless}" manifest m st pin_env pin_val
  manifest=$(sb_model_manifest)
  local -a rungs=()
  if [ -f "$manifest" ] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r pin_env; do
      [ -n "$pin_env" ] || continue
      # Indirect expansion, NOT eval: bash 3.2 supports ${!var} and an env value is
      # attacker-adjacent input that must never reach the parser.
      pin_val="${!pin_env:-}"
      [ -n "$pin_val" ] && rungs+=("$pin_val")
    done < <(jq -r --arg t "$tier" '.pins[$t][]? // empty' "$manifest" 2>/dev/null | tr -d '\r')
    while IFS= read -r m; do
      [ -n "$m" ] && rungs+=("$m")
    done < <(jq -r --arg s "$surface" --arg t "$tier" \
               '.ladders[$s][$t][]? // empty' "$manifest" 2>/dev/null | tr -d '\r')
  fi
  if [ "${#rungs[@]}" -eq 0 ]; then
    sb_log_error "lib.sh" "model-ladder unreadable or empty (tier=$tier surface=$surface); using sonnet" 1
    printf 'sonnet\n'; return 0
  fi
  if [ "${SB_MODEL_ELASTIC:-1}" = "0" ]; then printf '%s\n' "${rungs[0]}"; return 0; fi
  local idx=0
  # bash 3.2 + set -u: a bare "${rungs[@]}" aborts on an empty array — keep the +expansion guard.
  for m in ${rungs[@]+"${rungs[@]}"}; do
    st=$(sb_model_cache_get "$surface" "$m")
    if [ "$st" != "blocked" ]; then
      [ "$idx" -gt 0 ] && sb_log_error "lib.sh" \
        "model demotion: tier=$tier surface=$surface preferred=${rungs[0]} using=$m" 1
      printf '%s\n' "$m"; return 0
    fi
    idx=$(( idx + 1 ))
  done
  sb_log_error "lib.sh" \
    "model-ladder exhausted: tier=$tier surface=$surface all ${#rungs[@]} rungs blocked; using ${rungs[0]}" 1
  printf '%s\n' "${rungs[0]}"
  return 0
}

# Exit 0 = "this failure was the MODEL, not the network, not the credentials".
# PRIMARY signal is the process exit code plus the `is_error` envelope field. The headless JSON
# reports "subtype":"success" even on a model error, so subtype is never read.
# SECONDARY signal is a stdout/stderr signature, needed because a retired-but-known ID does not
# fail cleanly: it prints deprecation text and "There's an issue with the selected model (<id>)"
# onto stdout, poisoning the output stream while exiting 0.
sb_model_blocked_verdict() {
  local ec="${1:-0}" out="${2:-/dev/null}" err="${3:-/dev/null}" blob
  blob=$( { head -c 2000 "$out" 2>/dev/null; printf '\n'; head -c 2000 "$err" 2>/dev/null; } )
  # Auth first: an auth failure is an auth verdict. Misclassifying it would blocklist a model
  # that is perfectly available and demote the whole ladder on a login problem.
  if printf '%s' "$blob" | grep -qiE 'not logged in|please run /login|unauthorized|invalid api key'; then
    return 1
  fi
  if [ "$ec" != "0" ] && printf '%s' "$blob" | grep -qE '"is_error"[[:space:]]*:[[:space:]]*true'; then
    return 0
  fi
  # The wide signature list is diagnostic-output text from a FAILED spawn, so it is safe only
  # when ec != 0. On a clean exit (ec == 0) that same wide list is a trap: this plugin's own
  # extractor summarizes sessions about model deprecation, API errors, and this very feature, so
  # a successful summary saying "the model is deprecated" or "model not found" would be misread
  # as a failure, blocklisting a working model and demoting the whole ladder on its own prose. At
  # ec == 0 only the exact CLI-emitted phrase is trusted: it is the live-observed poisoned-output
  # case (a retired-but-known ID printing a warning to stdout while exiting 0), and it is the one
  # string in the list no summarized model-prose would independently produce.
  if [ "$ec" != "0" ]; then
    if printf '%s' "$blob" | grep -qiE "there's an issue with the selected model|not_found_error|model not found|permission_error|does not have access|was retired|is deprecated|invalid model"; then
      return 0
    fi
  else
    if printf '%s' "$blob" | grep -qiE "there's an issue with the selected model"; then
      return 0
    fi
  fi
  return 1
}

sb_note_model_blocked() {
  local surface="${1:-headless}" model="${2:-}" reason="${3:-}"
  [ -n "$model" ] || return 0
  sb_model_cache_put "$surface" "$model" blocked "$(printf '%s' "$reason" | tr -d '\n' | head -c 160)"
  sb_log_error "lib.sh" "model blocked: surface=$surface model=$model reason=$(printf '%s' "$reason" | tr -d '\n' | head -c 120)" 1
}

# --- Audit log ------------------------------------------------------------
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

# Resolve the plugin root: $CLAUDE_PLUGIN_ROOT when the hook harness sets it, else the lib.sh
# location (../) for manual invocation and tests. Single source for every script that needs to
# locate a bundled mcp/dist CLI — no per-call-site copy of this resolver (project rule).
sb_plugin_root() {
  local root="${CLAUDE_PLUGIN_ROOT:-}"
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    # ${BASH_SOURCE[0]} is this lib.sh; its parent is scripts/, grandparent is the plugin root.
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd) || root=""
  fi
  printf '%s' "$root"
}

# Copy SRC -> DST with invisible/Tags-block chars stripped, reusing the canonical TS sanitizer via
# the bundled sanitize-cli. NEVER mutates SRC (critical: dream staging may otherwise symlink the
# original transcript). Degrades to a plain copy + error-log entry if node/CLI is unavailable — the
# episodic TS read path is an independent second line of defense. (P6b.)
sb_strip_invisible_copy() {
  local src="$1" dst="$2"
  local cli; cli="$(sb_plugin_root)/mcp/dist/tools/sanitize-cli.bundle.js"
  if command -v node >/dev/null 2>&1 && [ -f "$cli" ] && node "$cli" < "$src" > "$dst" 2>/dev/null; then
    touch -r "$src" "$dst" 2>/dev/null || true   # preserve mtime (dream autostage watermark)
  else
    sb_log_error "dream-snapshot" "sanitize-cli unavailable or failed; staged UNSANITIZED copy of $(basename "$src")" 0
    cp -p "$src" "$dst"
  fi
}

# Regenerate wiki/index.md catalog after wiki writes.
sb_reindex_wiki() {
  local knowledge_dir="${1:-$(sb_knowledge_dir)}"
  knowledge_dir="${knowledge_dir/#\~/$HOME}"
  local plugin_root; plugin_root=$(sb_plugin_root)
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
  local knowledge_dir="${1:-$(sb_knowledge_dir)}"
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

# (sb_validate_wiki above must stay the SOLE definition in this file: bash's
# last-definition-wins means a later duplicate would shadow the count-returning
# one and silently kill dream-accept's "Normalized N pages" telemetry. Callers
# that don't want the count — ensure-dirs.sh, maintain-deterministic.sh —
# redirect stdout to /dev/null.)

# Pure auto-accept decision. Given the config mode and the
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

# Detect a project's slug / parent / root_path for a directory, monorepo-aware.
# Echoes a single TAB-separated line: <slug>\t<parent>\t<root_path>
#   - git submodule (superproject exists)                                       → <super>__<leaf>, parent=<super>
#   - single-git monorepo (workspace manifest at the git root, cwd in a subdir) → <root>__<leaf>, parent=<root>
#   - .sb-monorepo.json marker at an ancestor with a "parent" key               → <parent>__<leaf>, parent=<parent>
#   - otherwise (standalone, or working at the monorepo root)                    → <leaf>, parent=""
sb_detect_project() {
  local dir; dir=$(printf '%s' "${1:-$PWD}" | tr -d '\r')
  local abs; abs=$(cd "$dir" 2>/dev/null && pwd) || abs="$dir"
  local top; top=$(git -C "$abs" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
  local sup; sup=$(git -C "$abs" rev-parse --show-superproject-working-tree 2>/dev/null | tr -d '\r')
  local leaf; leaf=$(sb_slug_from_dir "$abs")

  # Windows path-form normalization: git rev-parse may return a Windows-form
  # path (C:/foo) while `cd && pwd` returns MSYS-form (/c/foo). Normalize the
  # git-returned paths to the same form as $abs before string-comparing, while
  # preserving the original git path for slug derivation (basename is form-agnostic).
  local top_norm; top_norm=$([ -n "$top" ] && { cd "$top" 2>/dev/null && pwd; } || printf '%s' "$top")

  # 1. git submodule: the superproject is the monorepo root.
  if [ -n "$sup" ]; then
    printf '%s__%s\t%s\t%s\n' "$(sb_slug_from_dir "$sup")" "$leaf" "$(sb_slug_from_dir "$sup")" "$abs"
    return 0
  fi

  # 2. single-git monorepo: a workspace manifest at the git root + cwd is a subdir of it.
  if [ -n "$top" ] && [ "$abs" != "$top_norm" ] && sb_is_workspace_root "$top"; then
    printf '%s__%s\t%s\t%s\n' "$(sb_slug_from_dir "$top")" "$leaf" "$(sb_slug_from_dir "$top")" "$abs"
    return 0
  fi

  # 3. .sb-monorepo.json marker walking up from cwd (sibling-repo topology).
  local marker; marker=$(sb_find_up "$abs" ".sb-monorepo.json")
  if [ -n "$marker" ]; then
    local pkey; pkey=$(jq -r '.parent // empty' "$marker" 2>/dev/null | tr -d '\r')
    # SECURITY: the marker is an in-repo file (an untrusted cloned repo could carry a hostile one).
    # pkey becomes a slug AND a `mkdir -p projects/<slug>` path component in setup — reject anything
    # that is not a clean slug (no `/`, no `..`, no spaces) so {"parent":"../../evil"} cannot traverse
    # out of the projects tree. An invalid marker is ignored (falls through to the standalone case).
    case "$pkey" in ''|.|..|*[!A-Za-z0-9._-]*) pkey="" ;; esac
    if [ -n "$pkey" ] && [ "$abs" != "$(dirname "$marker")" ]; then
      printf '%s__%s\t%s\t%s\n' "$pkey" "$leaf" "$pkey" "$abs"
      return 0
    fi
  fi

  # 4. standalone (or working at the monorepo root): bare slug, no parent.
  # Identity invariant: the origin REMOTE is the project identity; the folder basename
  # is only the fallback for remote-less dirs. A re-clone under a new folder name
  # (repo `name` cloned as `name-2`) must resolve to the registered slug instead of
  # minting a second project. No remote / no registry match / lookup failure all fall
  # open to the basename. (Monorepo cases 1-3 keep basename derivation — same bug
  # class but rarer; noted follow-up in the identity plan.)
  local rslug; rslug=$(sb_remote_override_slug "$abs" "$leaf")
  [ -n "$rslug" ] && leaf="$rslug"
  printf '%s\t\t%s\n' "$leaf" "${top:-$abs}"
}

# Echo the origin remote URL of a dir's git repo (empty if no remote / not a repo). CR-stripped.
# Phase C: doubles as collision identity (compared against an existing project's stored git_remote).
sb_git_remote() {
  local dir; dir=$(printf '%s' "${1:-$PWD}" | tr -d '\r')
  git -C "$dir" remote get-url origin 2>/dev/null | tr -d '\r' | head -1
}

# Canonicalize a git remote URL to its host/path identity so different URL forms of
# the same repository compare equal: trim, lowercase, drop the scheme (proto://) and
# any user@ prefix, fold the scp-form "host:path" colon to "/", strip trailing slashes
# and one trailing ".git". Empty in -> empty out.
# LOCKSTEP: three twins implement this — this function, the jq def in $SB_JQ_REMOTE_ID
# below, and normalizeRemote in mcp/src/brain-paths.ts. All are pinned to the shared
# fixture tests/fixtures/remote-normalization.tsv so they cannot drift.
sb_normalize_remote() {
  # tr 'A-Z' 'a-z', NOT '[:upper:]': ASCII-only lowercasing. BSD tr is multibyte-aware
  # under a UTF-8 locale and would fold non-ASCII (Ö→ö) that the jq twin's
  # ascii_downcase and the TS twin's ASCII-only fold leave alone — the three must agree.
  printf '%s' "${1:-}" | tr -d '\r' | tr 'A-Z' 'a-z' | sed -E '
    s#^[[:space:]]+##; s#[[:space:]]+$##;
    s#^[a-z+]+://##;
    s#^[^@/]*@##;
    s#^([^/:]+):#\1/#;
    s#/+$##; s#\.git$##; s#/+$##'
}

# jq twin of sb_normalize_remote (nrm), single-sourced in ONE variable so the registry
# lookup (sb_slug_from_remote) and the registry dedupe (sb_harden_projects_jsonl) share
# one definition and cannot fork. rkeep picks the canonical record from an array of
# records sharing one normalized remote: the slug equal to the remote's repo basename
# wins (the user-facing project name), else the record with the newest last_session_iso.
# The survivor's root_path may be stale for one session (it can point at another clone);
# session-load lazy-updates it on the next resolution from the live clone.
SB_JQ_REMOTE_ID='
  def nrm: ascii_downcase
    | sub("^\\s+";"") | sub("\\s+$";"")
    | sub("^[a-z+]+://";"")
    | sub("^[^@/]*@";"")
    | sub("^(?<h>[^/:]+):";"\(.h)/")
    | sub("/+$";"") | sub("\\.git$";"") | sub("/+$";"");
  def rkeep: ((.[0].git_remote | nrm | sub(".*/";"")) as $base
    | (map(select(.slug == $base)) | .[0]) // max_by(.last_session_iso // ""));
'

# Look up the registered slug that owns a git remote: sb_slug_from_remote <registry> <raw-url>.
# Echoes the canonical slug, or nothing when the remote/registry is absent or unmatched.
# Identity ENHANCEMENT, not a guard: a registry jq cannot parse logs loudly but FAILS
# OPEN to empty output (rc 0) so callers fall back to the basename slug.
sb_slug_from_remote() {
  local reg="${1:-}" raw="${2:-}"
  [ -n "$raw" ] && [ -f "$reg" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local want; want=$(sb_normalize_remote "$raw")
  [ -n "$want" ] || return 0
  local out
  # MSYS_NO_PATHCONV: on Git-Bash a bare-path remote (/srv/git/repo) passed as a jq
  # arg would be rewritten to a Windows path and never match the registry. The flag
  # suppresses conversion of EVERY argument, so the registry is fed via stdin
  # redirection (opened by bash, immune to conversion) instead of a path argument.
  if ! out=$(MSYS_NO_PATHCONV=1 jq -sr --arg want "$want" "$SB_JQ_REMOTE_ID"'
        [ .[] | select(type=="object")
              | select(((.slug // "") | type) == "string" and (.slug // "") != "")
              | select(((.git_remote // "") | type) == "string" and (.git_remote // "") != "")
              | select((.git_remote | nrm) == $want) ]
        | if length == 0 then empty else rkeep.slug end
      ' < "$reg" 2>/dev/null); then
    sb_log_error "lib.sh" "sb_slug_from_remote: jq could not parse $reg — remote lookup skipped (basename fallback)" 0
    return 0
  fi
  printf '%s\n' "$out" | tr -d '\r' | head -1
  return 0
}

# Remote-identity override for a basename-derived slug: echo the registered slug that
# owns DIR's origin remote when it is non-empty and DIFFERS from BASE, else nothing.
# Shared by BOTH funnels (sb_detect_project capture/registration, sb_resolve_slug
# query) so they cannot split-brain a re-cloned repo. Cost: one git spawn; the jq
# lookup only runs when a remote exists. Fails open to the basename.
# SECURITY: .git/config is attacker-writable text — a crafted origin matching a
# registered remote inherits that project's slug. The override therefore must never
# be silent: every firing is audit-logged (rule remote-identity-override). First-seen
# remote→slug pinning is the queued hardening.
sb_remote_override_slug() {
  local dir="$1" base="$2" gr rslug
  gr=$(sb_git_remote "$dir")
  [ -n "$gr" ] || return 0
  rslug=$(sb_slug_from_remote "$BRAIN_DIR/projects.jsonl" "$gr")
  [ -n "$rslug" ] && [ "$rslug" != "$base" ] || return 0
  sb_log_audit "slug-resolve" "flag" "remote-identity-override" "$dir" \
    "basename=$base remote=$gr slug=$rslug"
  printf '%s\n' "$rslug"
}

# Layer-1 migration: canonicalize projects.jsonl. Tolerates pretty-printed / JSON-array /
# CRLF / duplicate-slug input; rewrites to one compact record per line (LF), dedup by slug
# keeping the newest last_session_iso. Idempotent: a clean file is left untouched (no backup,
# no churn). Fail-loud: a file jq cannot parse at all is left INTACT (return 1), no silent loss.
sb_harden_projects_jsonl() {
  local f="${1:?projects.jsonl path required}"
  [ -f "$f" ] && [ -s "$f" ] || return 0          # absent / empty = nothing to harden
  command -v jq >/dev/null 2>&1 || { echo "harden: jq required" >&2; return 0; }
  local tmp; tmp=$(mktemp)
  # -s slurps the whole file (handles pretty-print + JSON-array); flatten unwraps an array;
  # drop non-objects/slug-less; dedup by slug keeping newest; -c one compact object per value;
  # tr -d '\r' keeps the file LF-only despite jq's CRLF stdout on Windows.
  # Remote-identity dedupe (after the slug dedup): records sharing one NORMALIZED
  # git_remote are the SAME repository re-cloned under different folder names —
  # collapse each group to its canonical record (rkeep). Records with an empty or
  # non-string git_remote are never grouped (no remote = no shared identity).
  if ! jq -sc "$SB_JQ_REMOTE_ID"'
        flatten | map(select(type=="object" and (.slug|type=="string") and .slug!=""))
        | group_by(.slug) | map(max_by(.last_session_iso // ""))
        | (map(select(((.git_remote // "") | type) != "string" or (.git_remote // "") == ""))) as $noremote
        | (map(select(((.git_remote // "") | type) == "string" and (.git_remote // "") != ""))
           | group_by(.git_remote | nrm)
           | map(if length > 1 then rkeep else .[0] end)) as $withremote
        | $noremote + $withremote | .[]' \
        "$f" 2>/dev/null | tr -d '\r' > "$tmp" || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "harden: could not parse $f — left intact (manual review)" >&2
    return 1
  fi
  if cmp -s "$f" "$tmp"; then rm -f "$tmp"; return 0; fi   # already canonical → no churn, no backup
  # Slugs a remote-identity collapse is about to DROP (computed from the pre-rewrite
  # file so the report names them even after the records are gone). Dropping a slug
  # redirects that project's future sessions — never silent.
  local dropped
  dropped=$(jq -sr "$SB_JQ_REMOTE_ID"'
      flatten | map(select(type=="object" and (.slug|type=="string") and .slug!=""))
      | group_by(.slug) | map(max_by(.last_session_iso // ""))
      | map(select(((.git_remote // "") | type) == "string" and (.git_remote // "") != ""))
      | group_by(.git_remote | nrm)
      | map(select(length > 1) | (map(.slug) - [rkeep.slug]))
      | flatten | join(",")' "$f" 2>/dev/null | tr -d '\r')
  local bak; bak="$f.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  if cp "$f" "$bak" && mv "$tmp" "$f"; then
    echo "harden: canonicalized $f (backup: $bak)"
    if [ -n "$dropped" ]; then
      echo "harden: remote-identity dedupe collapsed duplicate-remote slugs: $dropped (same origin remote = one project; backup: $bak)" >&2
      sb_log_error "lib.sh" "sb_harden_projects_jsonl: collapsed duplicate-remote slugs in $f: $dropped (backup: $bak)" 0
    fi
  else
    rm -f "$tmp"; echo "harden: rewrite failed for $f" >&2; return 1
  fi
}

# Setup collision identity. Given the registry, a candidate slug and its dir identity, classify:
#   new       — no record with this slug
#   same      — record exists AND (identity matches; OR the stored record has NO identity yet —
#               a legacy/pre-0.33 record — so there is nothing to conflict with: lazy-fill it)
#   collision — record exists AND its STORED identity differs (two different repos sharing a slug)
# Collision keys on the STORED identity, never the freshly-detected one: a legacy record without
# git_remote/root_path must lazy-fill as the same project, not false-collide just because a remote
# is now detectable. Path compare is form-canonicalized (MSYS /c vs Windows C:\, like toBashPath).
sb_project_identity() {
  local reg="$1" slug="$2" rp="$3" gr="$4"
  [ -f "$reg" ] || { echo "new"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "new"; return 0; }
  local rec; rec=$(jq -c --arg s "$slug" 'select(.slug==$s)' "$reg" 2>/dev/null | head -1)
  [ -n "$rec" ] || { echo "new"; return 0; }
  local ex_rp ex_gr
  ex_rp=$(printf '%s' "$rec" | jq -r '.root_path // ""')
  ex_gr=$(printf '%s' "$rec" | jq -r '.git_remote // ""')
  _norm() { printf '%s' "${1:-}" | tr -d '\r' | sed -E 's#\\#/#g; s#^([A-Za-z]):/#/\L\1/#; s#/+$##'; }
  if [ -n "$ex_gr" ]; then
    # stored record HAS a remote identity → authoritative compare
    [ "$gr" = "$ex_gr" ] && echo "same" || echo "collision"
  elif [ -n "$ex_rp" ]; then
    # stored record has a path identity but no remote → compare normalized paths
    [ "$(_norm "$rp")" = "$(_norm "$ex_rp")" ] && echo "same" || echo "collision"
  else
    # stored record carries NO identity (legacy) → nothing to conflict with → same (lazy-fill)
    echo "same"
  fi
}

# True if DIR contains a recognized monorepo workspace manifest.
sb_is_workspace_root() {
  local d="$1"
  [ -f "$d/pnpm-workspace.yaml" ] || [ -f "$d/nx.json" ] || [ -f "$d/turbo.json" ] \
    || [ -f "$d/lerna.json" ] || [ -f "$d/go.work" ] \
    || { [ -f "$d/Cargo.toml" ] && grep -q '^\[workspace\]' "$d/Cargo.toml" 2>/dev/null; } \
    || { [ -f "$d/package.json" ] && jq -e 'has("workspaces")' "$d/package.json" >/dev/null 2>&1; }
}

# Walk up from DIR looking for FILE; echo its full path, or nothing.
sb_find_up() {
  local d="$1" file="$2"
  d=$(cd "$d" 2>/dev/null && pwd) || return 0
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/$file" ] && { printf '%s\n' "$d/$file"; return 0; }
    d=$(dirname "$d")
  done
  [ -f "/$file" ] && printf '%s\n' "/$file"
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
  local cwd="${1:-$PWD}" _s _r
  # 1. CLAUDE_PROJECT_DIR — per-process project root (set by Claude Code when present).
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    _s=$(sb_slug_from_dir "$CLAUDE_PROJECT_DIR")
    case "$_s" in /|.|..) ;; *)
      # Remote identity beats the basename (a re-clone under a new folder name must
      # resolve the REGISTERED slug) — same lookup as sb_detect_project, so the
      # capture funnel and this query funnel can never split-brain one repo.
      _r=$(sb_remote_override_slug "$CLAUDE_PROJECT_DIR" "$_s")
      echo "${_r:-$_s}"; return 0 ;;
    esac
  fi
  # 2. cwd, but ONLY when its basename names a KNOWN project (projects/<slug>/ exists).
  #    cwd is per-process, so it can't be clobbered by a concurrent session like the shared
  #    pin can — but the known-project gate rejects a subdir cwd (→ falls to the pin below).
  #    Remote identity outranks the known-project gate here too (same rationale as tier 1).
  _s=$(sb_slug_from_dir "$cwd")
  case "$_s" in /|.|..) _s="" ;; esac
  if [ -n "$_s" ]; then
    _r=$(sb_remote_override_slug "$cwd" "$_s")
    if [ -n "$_r" ]; then echo "$_r"; return 0; fi
    if [ -f "$BRAIN_DIR/projects/$_s/PROJECT.md" ]; then echo "$_s"; return 0; fi
  fi
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

# There is deliberately NO sb_clear_extraction_marker. Markers are GC'd by
# extract-drain.sh's `-mtime +30 -delete` sweep, never cleared per run: a
# per-run clear would re-extract the same transcript window on every Stop
# (the 18x re-archive bug class). The sb_get_/sb_set_/sb_extraction_marker_key
# trio is the complete API.

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
# no indexer change.
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
      | while IFS= read -r f; do printf '%s %s\n' "$(sb_mtime "$f")" "$f"; done \
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

# Write a machine-GENERATED wiki page with born-valid frontmatter (the
# generated-page contract). The churn
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
# Deletes oldest files first, ranked by MTIME (see below — NOT by filename).
sb_prune_transcripts() {
  local archive_dir="$BRAIN_DIR/transcripts"
  [ -d "$archive_dir" ] || return 0

  # OLDEST-first by mtime, NOT a lexical filename sort. Archives are named
  # "${session_id}_${slug}_${date}.txt" — the random session UUID LEADS, so
  # `sort` orders by UUID hex (age-random): the cap would then evict a
  # just-archived, not-yet-drained transcript, silently breaking the "the
  # transcript is still archived; the drainer mines the real knowledge later"
  # recovery contract (stop-extract.sh). mtime is the true age. -printf is GNU;
  # fall back to a stat-based sort on BSD/macOS — the same idiom the sub-*.txt
  # cap in sb_archive_transcript already uses.
  local files
  files=$(find "$archive_dir" -name '*.txt' -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | cut -d' ' -f2-)
  if [ -z "$files" ]; then
    files=$(find "$archive_dir" -name '*.txt' -type f 2>/dev/null \
      | while IFS= read -r f; do printf '%s %s\n' "$(sb_mtime "$f")" "$f"; done \
      | sort -n | cut -d' ' -f2-)
  fi
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

# --- Maintainer auto-dispatch state helpers -----------------------------
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

# No dream dir/status helpers exist here by design: dream paths are composed
# inline as "$BRAIN_DIR/dreams/<id>" and status reads are inline jq — the
# canonical pattern across the scripts.

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
  smt=$(sb_mtime "$sf")
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
  local TBIN resp _payload_tmp
  TBIN=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
  # Use a temp file for the payload: Windows curl (MinGW) cannot read /dev/fd/N
  # process-substitution paths that work on Linux/macOS. @tmpfile is portable.
  _payload_tmp=$(mktemp) && printf '%s' "$payload" > "$_payload_tmp" || { rm -f "$_payload_tmp"; return 1; }
  resp=$( ${TBIN:+"$TBIN" "$timeout_s"} curl -sS "${url%/}/v1/chat/completions" \
    -H 'content-type: application/json' --data-binary "@$_payload_tmp" 2>/dev/null )
  local _ec=$?; rm -f "$_payload_tmp"; [ $_ec -eq 0 ] || return 1
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
  # SB_USE_BWRAP=1 (opt-in): wrap the claude invocation in
  # bubblewrap so the extractor sees a read-only root with only
  # ~/.second-brain writable. Requires bwrap binary;
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
      local resp _b2_tmp
      # Honor ANTHROPIC_BASE_URL for enterprise gateways / proxies / air-gapped
      # Anthropic-compatible endpoints; default to the public host.
      # Payload via temp file: Windows curl (MinGW) cannot read /dev/fd/N
      # process-substitution paths; @tmpfile is portable across all platforms.
      # (Previous comment noted </dev/null to prevent stdin inheritance by stubs
      # — the temp file approach avoids that too since curl never reads stdin.)
      _b2_tmp=$(mktemp) && printf '%s' "$payload" > "$_b2_tmp" || { rm -f "$_b2_tmp" 2>/dev/null; _b2_tmp=""; }
      if [ -z "$_b2_tmp" ]; then resp=""; else
      resp=$(timeout "$timeout_s" curl -sS "${ANTHROPIC_BASE_URL:-https://api.anthropic.com}/v1/messages" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        --data-binary "@$_b2_tmp" 2>"$err_file" || true)
      rm -f "$_b2_tmp"; fi

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

# Count out-of-band DRAIN TIMEOUTS (extractor-diag ... ec=124) in the most-recent
# window of error-log.jsonl. This is the SILENT-FAILURE signature the legacy
# sb_count_recent_extraction_failures MISSES: extract-drain.sh logs these via
# sb_log_extractor_diag at exit_code 0 (TRACE), and `claude -p` hanging past the
# timeout (recursive-claude / OAuth lock with no API-key backstop) is exactly the
# ec=124 case. We scan the raw .message text (not jq-parsed fields). tail-bounded
# to the recent window so a long-ago, since-fixed burst doesn't re-nag forever.
# $1 = window size (lines, default 40). Pure read; safe to call anywhere.
sb_count_drain_timeouts() {
  local win="${1:-40}"; case "$win" in ''|*[!0-9]*) win=40 ;; esac
  local log="$BRAIN_DIR/error-log.jsonl"
  [ -f "$log" ] || { echo 0; return; }
  tail -n "$win" "$log" 2>/dev/null \
    | grep -c 'extractor-diag .*ec=124' 2>/dev/null || true
}

# Count transcripts that reached a TERMINAL error in the drainer's done-set
# (.extraction-state.jsonl outcome=="error" = poison-pilled past SB_DRAIN_MAX_FAILS).
# Folded per-basename so a basename that retried then errored counts ONCE.
# Echoes an integer. $1 = optional explicit state-file path (test override).
sb_count_drain_dead_letters() {
  local f="${1:-$BRAIN_DIR/.extraction-state.jsonl}"
  [ -s "$f" ] || { echo 0; return 0; }
  if command -v jq >/dev/null 2>&1; then
    jq -nR 'reduce (inputs|fromjson?) as $r ({}; .[$r.basename]=$r)
            | [.[]] | map(select(.outcome=="error")) | length' "$f" 2>/dev/null || echo 0
  else
    echo 0
  fi
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

# --- Out-of-band extraction helpers ---------------------------------------
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

  local kdir; kdir="$(sb_knowledge_dir)"
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

  local sigs; sigs=$(printf '%s' "$delta" | jq -c \
    '{persona_signals: (.persona_signals // []), rule_candidates: (.rule_candidates // [])}' 2>/dev/null)
  if [ -n "$sigs" ] && printf '%s' "$sigs" \
    | jq -e '(.persona_signals | length) + (.rule_candidates | length) > 0' >/dev/null 2>&1; then
    printf '%s' "$sigs" | bash "$sdir/merge-persona-signals.sh" 2>/dev/null || true
  fi
  return 0
}

# Detect Claude Code's built-in auto-memory state. Pure-bash, offline, fail-soft
# (never errors out; defaults to "on" rather than non-zero). Emits key=value
# lines on stdout: state, reason, path, files, memory_lines. Consumed by the
# status + audit skills to surface the native store alongside the second-brain.
# See archive/docs branch, docs/specs/2026-05-29-auto-memory-coordination-design.md.
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
  # Helper: normalize a git-returned path to the shell's native POSIX form.
  # On Windows/MSYS2, git rev-parse may return C:/foo while `cd && pwd` returns
  # /c/foo; converting via `cd && pwd` makes the result match $TMP/$HOME etc.
  _sb_am_normpath() {
    local p="$1"
    [ -z "$p" ] && return 0
    local norm; norm=$(cd "$p" 2>/dev/null && pwd) && printf '%s' "$norm" || printf '%s' "$p"
  }

  if [ -z "$path" ]; then
    local project_root dashed
    project_root=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null | tr -d '\r' || true)
    [ -n "$project_root" ] && project_root=$(_sb_am_normpath "$project_root")
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
  # fall back to the safe default. (Consumers must never eval this output — defense in depth.)
  case "$path" in
    *[!\ /A-Za-z0-9._~-]*)
      local project_root dashed
      project_root=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null | tr -d '\r' || true)
      [ -n "$project_root" ] && project_root=$(_sb_am_normpath "$project_root")
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

# --- Out-of-band drainer scheduler state (P1 Task 3) ---------------------
# Is the per-OS extract-drain scheduler registered? Returns 0 (installed) / 1 (absent).
# OS arg optional ($1); else SB_INSTALL_OS_OVERRIDE; else uname-derived (systemd|launchd|windows).
# Signal = the install artifact the matching install-extract-timer.sh --apply branch writes and
# --uninstall removes: the systemd user TIMER unit (Linux) / the LaunchAgent plist (macOS) / a
# live schtasks query (Windows leaves no file artifact, so we ask the scheduler). Using the unit
# FILE rather than `systemctl --user is-enabled` keeps this portable and unit-testable, and stays
# in lockstep with what uninstall deletes. A unit present-but-administratively-disabled is a rare
# partial state that the self-healing --ensure re-applies harmlessly.
sb_timer_installed() {
  local os="${1:-${SB_INSTALL_OS_OVERRIDE:-}}"
  if [ -z "$os" ]; then
    case "$(uname -s 2>/dev/null)" in
      Linux)                os=systemd ;;
      Darwin)               os=launchd ;;
      MINGW*|MSYS*|CYGWIN*)  os=windows ;;
      *)                    os=unsupported ;;
    esac
  fi
  # The scheduler unit/plist/task all exec $BRAIN_DIR/bin/sb-extract-drain.sh, so a
  # registered-but-shim-less state — e.g. a stale task left by an old plugin version whose shim was
  # GC'd (observed live: a task execing a deleted shim, failing silently every fire) — is BROKEN and
  # must read as not-installed, so --ensure / the session-load self-heal re-applies and regenerates
  # the shim. write_shim writes this path on EVERY --apply across all OSes, so its presence is a
  # universal health signal layered on top of the per-OS registration check below.
  [ -f "${BRAIN_DIR:-$HOME/.second-brain}/bin/sb-extract-drain.sh" ] || return 1
  case "$os" in
    systemd)
      [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/sb-extract-drain.timer" ] ;;
    launchd)
      [ -f "$HOME/Library/LaunchAgents/sb-extract-drain.plist" ] ;;
    windows)
      MSYS_NO_PATHCONV=1 schtasks /Query /TN sb-extract-drain >/dev/null 2>&1 ;;
    *)
      return 1 ;;
  esac
}

# One-line human status of the drainer scheduler: "installed" | "absent" (passes $@ through to
# sb_timer_installed, so an explicit OS arg is honoured). For the session-load capture banner.
sb_timer_health() {
  if sb_timer_installed "$@"; then echo installed; else echo absent; fi
}
