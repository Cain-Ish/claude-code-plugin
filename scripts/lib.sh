#!/bin/bash
# Shared functions for second-brain hook scripts.
# Source this at the top of any hook script: source "$(dirname "$0")/lib.sh"

BRAIN_DIR="$HOME/.second-brain"

# Parse hook input from stdin. Sets: SB_INPUT, SB_SESSION_ID, SB_TRANSCRIPT_PATH, SB_TIMESTAMP
sb_parse_input() {
  SB_INPUT=$(cat)
  SB_SESSION_ID=$(echo "$SB_INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
  SB_TRANSCRIPT_PATH=$(echo "$SB_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
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
sb_log_error() {
  local script_name="${1:-unknown}"
  local error_msg="${2:-}"
  local exit_code="${3:-1}"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg t "$ts" \
      --arg s "$script_name" \
      --arg m "$error_msg" \
      --argjson c "$exit_code" \
      '{timestamp:$t, script:$s, message:$m, exit_code:$c}' \
      >> "$BRAIN_DIR/error-log.jsonl" 2>/dev/null
  else
    local esc_script esc_msg
    esc_script=$(printf '%s' "$script_name" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_msg=$(printf '%s' "$error_msg" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"timestamp":"%s","script":"%s","message":"%s","exit_code":%s}\n' \
      "$ts" "$esc_script" "$esc_msg" "$exit_code" \
      >> "$BRAIN_DIR/error-log.jsonl" 2>/dev/null
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
    SB_BUNDLE="$reindex_js" SB_KDIR="$knowledge_dir" \
      node --input-type=module -e "
        const m = await import(process.env.SB_BUNDLE);
        await m.knowledgeReindex(process.env.SB_KDIR);
      " 2>/dev/null || true
  fi
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

# Read the active session slug pinned by session-load.sh. Falls back to
# basename of $1 if the pin file is missing (first-run or stale state).
sb_resolve_slug() {
  local cwd="${1:-$PWD}"
  local pinned="$BRAIN_DIR/.active-session-slug"

  if [ -f "$pinned" ]; then
    local slug
    slug=$(tr -d '[:space:]' < "$pinned")
    if [ -n "$slug" ] && [ -f "$BRAIN_DIR/projects/$slug/PROJECT.md" ]; then
      echo "$slug"
      return 0
    fi
  fi

  echo "$(basename "$cwd")"
  return 0
}

# Strip markdown code fences from LLM output. Models sometimes wrap JSON in
# ```json ... ``` despite being told not to. Reads stdin, writes stdout.
sb_strip_code_fences() {
  sed '1s/^```[a-zA-Z]*[[:space:]]*//' | sed '$ s/[[:space:]]*```[[:space:]]*$//'
}

# --- Extraction marker helpers ---
# Track which transcript lines have been extracted so pre-compact and stop
# hooks process disjoint windows — nothing lost, nothing duplicated.

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
# Shared by stop-extract.sh, pre-compact.sh, and batch-extract.sh.
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

# Enforce transcript archive caps: 100 files max, 5MB total.
# Deletes oldest files first (sorted by filename which embeds date).
sb_prune_transcripts() {
  local archive_dir="$BRAIN_DIR/transcripts"
  [ -d "$archive_dir" ] || return 0

  local files
  files=$(find "$archive_dir" -name '*.txt' -type f 2>/dev/null | sort)
  local count
  count=$(echo "$files" | grep -c . 2>/dev/null || echo 0)

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
  [ -f "$f" ] && n=$(cat "$f" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%d' "$((n+1))" > "$f.tmp" && mv "$f.tmp" "$f"
}

sb_get_wiki_writes() {  # $1 = slug
  local v
  v=$(cat "$BRAIN_DIR/projects/$1/.wiki-writes" 2>/dev/null || echo 0)
  case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

sb_set_wiki_writes() {  # $1 = slug, $2 = int
  local f="$BRAIN_DIR/projects/$1/.wiki-writes"
  mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '%d' "$2" > "$f.tmp" && mv "$f.tmp" "$f"
}

sb_reset_wiki_writes() { sb_set_wiki_writes "$1" 0; }

sb_inc_maintainer_fails() {  # $1 = slug
  local f="$BRAIN_DIR/projects/$1/.maintainer-fail-count"
  mkdir -p "$(dirname "$f")" 2>/dev/null
  local n=0
  [ -f "$f" ] && n=$(cat "$f" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%d' "$((n+1))" > "$f.tmp" && mv "$f.tmp" "$f"
}

sb_get_maintainer_fails() {  # $1 = slug
  local v
  v=$(cat "$BRAIN_DIR/projects/$1/.maintainer-fail-count" 2>/dev/null || echo 0)
  case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
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

# --- Dream lifecycle helpers ---

sb_generate_dream_id() {
  echo "drm_$(date -u +%Y%m%dT%H%M%SZ)"
}

sb_dream_dir() {
  echo "$BRAIN_DIR/dreams/${1:?dream_id required}"
}

sb_dream_status() {
  local dream_id="$1"
  local status_file="$BRAIN_DIR/dreams/$dream_id/status.json"
  [ -f "$status_file" ] && cat "$status_file" || echo '{}'
}

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

# --- Extractor backend & health tracking ---------------------------------
# Unified entry point for both stop-extract.sh and pre-compact.sh. Tries the
# `claude` CLI first; if its auth is broken, falls back to a direct Messages
# API call via curl using $ANTHROPIC_API_KEY. Writes a health marker to
# $BRAIN_DIR/.extractor-health.json so session-load.sh can surface the state
# to the user on the next SessionStart, instead of failing silently.

SB_HEALTH_FILE="$BRAIN_DIR/.extractor-health.json"

# Write health snapshot. $1=backend ("claude-cli"|"anthropic-api"|"none"),
# $2=ok|fail, $3=reason (short string).
sb_write_extractor_health() {
  local backend="$1" status="$2" reason="${3:-}"
  local ts
  ts=$(date -u +%FT%TZ)
  mkdir -p "$BRAIN_DIR" 2>/dev/null
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg t "$ts" --arg b "$backend" --arg s "$status" --arg r "$reason" \
      '{checked_at:$t, backend:$b, status:$s, reason:$r}' \
      > "$SB_HEALTH_FILE" 2>/dev/null
  fi
}

# Call configured extractor. Reads stdin from $1 file, writes JSON to $2.
# $3 = model id, $4 = system prompt, $5 = timeout seconds.
# Returns 0 if output exists and is a JSON object, 1 otherwise.
# Always writes a health marker before returning.
sb_call_extractor() {
  local input_file="$1" out_file="$2" model="$3" prompt="$4" timeout_s="${5:-30}"
  local err_file
  err_file=$(mktemp)

  # --- Backend 1: claude CLI -----------------------------------------------
  # `--bare` is a perf optimization (skips hooks/LSP, saves ~10s) but per
  # `claude --help`: bare-mode auth is STRICTLY ANTHROPIC_API_KEY — OAuth
  # tokens from `claude /login` are never read. So we only use --bare when
  # an API key is present; otherwise we use the slower full path that
  # honors OAuth. Override with SB_USE_BARE=1 to force.
  if command -v claude >/dev/null 2>&1; then
    local -a CLI_ARGS=(-p --model "$model" --system-prompt "$prompt")
    if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ "${SB_USE_BARE:-0}" = "1" ]; then
      CLI_ARGS=(-p --bare --model "$model" --system-prompt "$prompt")
    fi
    if command -v timeout >/dev/null 2>&1; then
      timeout "$timeout_s" claude "${CLI_ARGS[@]}" \
        < "$input_file" > "$out_file" 2>"$err_file" || true
    else
      claude "${CLI_ARGS[@]}" \
        < "$input_file" > "$out_file" 2>"$err_file" || true
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
      sb_write_extractor_health "claude-cli" "fail" \
        "empty output: $(head -c 100 "$err_file" | tr '\n' ' ')"
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
      resp=$(timeout "$timeout_s" curl -sS https://api.anthropic.com/v1/messages \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        --data-binary @<(printf '%s' "$payload") 2>"$err_file" || true)

      local text
      text=$(printf '%s' "$resp" | jq -r '.content[0].text // empty' 2>/dev/null)

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
        api_err=$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null)
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
    | grep -c 'llm-extraction-failed' 2>/dev/null || echo 0
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
