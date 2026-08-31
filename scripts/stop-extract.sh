#!/bin/bash
# Stop-hook orchestrator. Reads the Stop hook payload, decides
# whether the session was substantive enough to extract from, calls the
# `claude` CLI as a subprocess to produce a structured JSON delta, and
# pipes that delta into merge-project-update.sh.
#
# Replaces the older run-stop-predicate.sh entry that only wrote a flag
# file nobody read. The baseline-vs-current PROJECT.md predicate is no
# longer the gate (PROJECT.md only changes if extraction ran, so it's
# circular). The new gate is "transcript has at least one tool_use" —
# pure Q&A sessions skip the LLM call.
#
# Always exits 0 (fail-soft). A crash in this hook must never block
# Claude's stop event.
#
# Honors env overrides:
#   SB_EXTRACTOR_MODEL — model passed via `claude -p --model <id>`
#                        (no literal default: the extractor asks for the MID tier and
#                        sb_resolve_model walks the model-ladder.json headless ladder,
#                        where SB_EXTRACTOR_MODEL is declared as a pin at rung 0)
#   SB_EXTRACT_TIMEOUT — seconds to wait for `claude` (default: 25)
set -u
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0

# Defensive lib.sh source. If lib.sh is missing the script would crash on
# first $BRAIN_DIR reference under `set -u` and leave no trace. Without
# sb_log_error available we fall back to a raw append so the failure is
# at least diagnosable.
LIB="$(dirname "$0")/lib.sh"
if ! source "$LIB" 2>/dev/null; then
  printf '{"timestamp":"%s","script":"stop-extract.sh","message":"lib.sh source failed: %s","exit_code":0}\n' \
    "$(date -u +%FT%TZ)" "$LIB" >> "$HOME/.second-brain/error-log.jsonl" 2>/dev/null
  exit 0
fi

# Hook trace tag — set by each gate before exit, written by EXIT trap. Lets
# the next /second-brain:status surface exactly which gate the script tripped.
SB_GATE=""
log_gate() { SB_GATE="$1"; }
trap '[ -n "$SB_GATE" ] && sb_log_error "stop-extract.sh" "gate=$SB_GATE" 0' EXIT

# Tier intent, not a literal: SB_EXTRACTOR_MODEL is declared as a MID pin in model-ladder.json
# and is applied by sb_resolve_model as rung 0, per attempt, inside sb_call_extractor.
EXTRACTOR_MODEL="tier:mid"
EXTRACT_TIMEOUT="${SB_EXTRACT_TIMEOUT:-25}"

RAW=$(cat 2>/dev/null || true)
if [ -z "$RAW" ]; then log_gate "empty-stdin"; exit 0; fi

if ! echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1; then
  log_gate "stdin-not-json-object"
  exit 0
fi

TRANSCRIPT=$(echo "$RAW" | jq -r '.transcript_path // empty' 2>/dev/null | tr -d '\r')
CWD=$(echo       "$RAW" | jq -r '.cwd             // empty' 2>/dev/null | tr -d '\r')
SESSION_ID=$(echo "$RAW" | jq -r '.session_id     // "unknown"' 2>/dev/null | tr -d '\r')
if [ -z "$TRANSCRIPT" ]; then log_gate "transcript-path-empty cwd=$CWD"; exit 0; fi
if [ ! -f "$TRANSCRIPT" ]; then log_gate "transcript-file-missing path=$TRANSCRIPT"; exit 0; fi

if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  SLUG=$(sb_resolve_slug "$CWD")
else
  SLUG=$(sb_resolve_slug "$PWD")
fi
if [ -z "$SLUG" ]; then log_gate "slug-empty cwd=$CWD pwd=$PWD"; exit 0; fi
MARKER_KEY=$(sb_extraction_marker_key "$SLUG" "$SESSION_ID")

PROJECT_MD="$BRAIN_DIR/projects/$SLUG/PROJECT.md"
KNOWLEDGE_DIR="$(sb_knowledge_dir)"
if [ ! -f "$PROJECT_MD" ]; then
  mkdir -p "$(dirname "$PROJECT_MD")"
  cat > "$PROJECT_MD" <<TMPL
# PROJECT: $SLUG

## Goal
(auto-scaffolded — describe this project's goal)

## State

## Plan

## Conventions

## Handoff

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: $(date -u +%Y-%m-%dT%H:%M:%SZ) -->
<!-- last_queried_wiki: -->
TMPL
fi
mkdir -p "$KNOWLEDGE_DIR/wiki" 2>/dev/null || true

# --- Determine unprocessed window (disjoint with pre-compact extractions) ---
LAST_LINE=$(sb_get_extraction_marker "$MARKER_KEY")
# Record count, NOT `wc -l`: the Stop hook can read the transcript before the final
# JSONL line's trailing newline is flushed, and `wc -l` counts newlines — undercounting
# by one. That dropped line (often the last/only tool_use) would be excluded from the
# substantive gate + extractor + archive, AND the marker would advance past it so it's
# never recovered. awk NR counts records regardless of a missing final newline.
TOTAL_LINES=$(awk 'END{print NR}' "$TRANSCRIPT" 2>/dev/null)
# Stale-marker clamp (deep-review): a marker past EOF (transcript shrank, or a
# key collision via the session_id "unknown" fallback) would gate extraction
# forever now that markers are never cleared — treat it as no marker.
if [ "$LAST_LINE" -gt "$TOTAL_LINES" ]; then
  LAST_LINE=0
fi
NEW_LINES=$((TOTAL_LINES - LAST_LINE))

if [ "$NEW_LINES" -lt 1 ]; then
  log_gate "no-new-lines marker=$LAST_LINE total=$TOTAL_LINES"
  exit 0
fi

# --- Loop telemetry (utilization / value / compounding) — OBSERVATION ONLY ---
# Machine-locked by mcp/src/telemetry-firewall.test.ts: nothing
# here may ever feed ranking/forgetting. Gated on the session's injection manifest
# (written by session-load), so it runs EXACTLY ONCE per session (manifest deleted
# after) and scans only the new-lines window (same disjoint-window discipline as
# extraction) so a resume can't double-count history. Deterministic jq only — no
# LLM, transcript is DATA. Fail-soft: a telemetry error must never fail the hook.
if [ "${SB_TELEMETRY:-on}" != "off" ]; then
  MANIFEST_SID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9_-' | head -c 64)
  MANIFEST="$BRAIN_DIR/.injected-manifest-$MANIFEST_SID.jsonl"
  if [ -n "$MANIFEST_SID" ] && [ -f "$MANIFEST" ]; then
    TEL_WINDOW=$(awk -v s="$LAST_LINE" 'NR>s' "$TRANSCRIPT" 2>/dev/null)
    # utilization: Skill + Task(subagent_type) invocations -> counts store.
    TEL_NAMES=$(printf '%s\n' "$TEL_WINDOW" | jq -r '
      select(.type=="assistant") | .message.content[]? | select(.type=="tool_use")
      | if .name=="Skill" then ("skill:" + (.input.skill // "unknown"))
        elif .name=="Task" then ("agent:" + (.input.subagent_type // "unknown"))
        else empty end
    ' 2>/dev/null | tr -d '\r')
    if [ -n "$TEL_NAMES" ]; then
      UTIL_JSON="$BRAIN_DIR/utilization-counts.json"
      # Key aging (state hygiene): the counts store is append-keyed and never shrank —
      # a skill/agent used once a year ago kept its row forever. After the fold, drop
      # entries whose last_used is older than 180 days. Cutoff via the cross-platform
      # date fallback (GNU -d twin of BSD -v). last_used is a full ISO timestamp, so a
      # date-only cutoff compares correctly lexicographically (prefix rule).
      UTIL_CUTOFF=$(date -u -v-180d +%Y-%m-%d 2>/dev/null \
        || date -u -d '180 days ago' +%Y-%m-%d 2>/dev/null || echo '1970-01-01')
      TEL_TMP=$(mktemp 2>/dev/null) && {
        { [ -s "$UTIL_JSON" ] && cat "$UTIL_JSON" 2>/dev/null || echo '{}'; } \
          | jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg names "$TEL_NAMES" --arg cutoff "$UTIL_CUTOFF" '
              . as $base | reduce ($names | split("\n") | map(select(length>0)))[] as $n ($base;
                .[$n] = {count: ((.[$n].count // 0) + 1), last_used: $now})
              | with_entries(select(.value.last_used >= $cutoff))
            ' > "$TEL_TMP" 2>/dev/null \
          && mv "$TEL_TMP" "$UTIL_JSON" 2>/dev/null \
          || { rm -f "$TEL_TMP"; sb_log_error "stop-extract.sh" "telemetry: utilization fold failed (corrupt store? $UTIL_JSON)" 1; }
      }
    fi
    # value + compounding: injected ids subsequently used this session.
    TEL_READS=$(printf '%s\n' "$TEL_WINDOW" | jq -r '
      select(.type=="assistant") | .message.content[]? | select(.type=="tool_use")
      | select(.name=="Read") | .input.file_path // empty' 2>/dev/null | tr -d '\r' | tr '\\' '/')
    TEL_FETCH=$(printf '%s\n' "$TEL_WINDOW" | jq -r '
      select(.type=="assistant") | .message.content[]? | select(.type=="tool_use")
      | select(.name | test("knowledge_fetch|knowledge_neighbors|code_neighbors"))
      | (.input.slug // .input.node // empty)' 2>/dev/null | tr -d '\r')
    TEL_INJ=0; TEL_HIT=0; TEL_PRIOR=0; TEL_HITS=""
    TEL_TODAY=$(date -u +%Y-%m-%d)
    while IFS= read -r _tel_line; do
      [ -z "$_tel_line" ] && continue
      _tel_kind=$(printf '%s' "$_tel_line" | jq -r '.kind // empty' 2>/dev/null | tr -d '\r')
      _tel_id=$(printf '%s' "$_tel_line" | jq -r '.id // empty' 2>/dev/null | tr -d '\r')
      [ -n "$_tel_id" ] || continue
      TEL_INJ=$((TEL_INJ + 1))
      _tel_hit=0
      case "$_tel_kind" in
        codemap)
          { printf '%s\n' "$TEL_READS" | grep -qF "$_tel_id" || printf '%s\n' "$TEL_FETCH" | grep -qF "$_tel_id"; } && _tel_hit=1 ;;
        wiki|graph)
          { printf '%s\n' "$TEL_FETCH" | grep -qxF "$_tel_id" || printf '%s\n' "$TEL_READS" | grep -qF "/$_tel_id.md"; } && _tel_hit=1 ;;
      esac
      if [ "$_tel_hit" = 1 ]; then
        TEL_HIT=$((TEL_HIT + 1)); TEL_HITS="${TEL_HITS:+$TEL_HITS,}$_tel_id"
        # A hit on a page CREATED before today = prior-session knowledge reused.
        if [ "$_tel_kind" = "wiki" ] || [ "$_tel_kind" = "graph" ]; then
          _tel_pf=$(find "$KNOWLEDGE_DIR/wiki" -maxdepth 2 -name "$_tel_id.md" 2>/dev/null | head -1)
          if [ -n "$_tel_pf" ]; then
            _tel_created=$(sed -n 's/^created:[[:space:]]*//p' "$_tel_pf" 2>/dev/null | head -1 | tr -d '\r"')
            [ -n "$_tel_created" ] && [ "$_tel_created" \< "$TEL_TODAY" ] && TEL_PRIOR=$((TEL_PRIOR + 1))
          fi
        fi
      fi
    done < "$MANIFEST"
    # ec=0 gate= trace -> audit-log; one row per session.
    sb_log_error "stop-extract.sh" "gate=value-loop injected=$TEL_INJ read=$TEL_HIT prior=$TEL_PRIOR hits=${TEL_HITS:-none}" 0
    rm -f "$MANIFEST"
  fi
  # GC stray per-session markers from sessions that never reached a Stop (7d, same
  # policy as the .injected/ memos). Covers the telemetry manifest AND the three
  # verify-gate session markers (.verify-gate-blocks-*, .verify-gate-agseen-*,
  # .critic-offer-*), which are written per-session by stop-verify-gate.sh and were
  # never swept. One find, -o group. Deliberately quiet: GC of already-lost state.
  find "$BRAIN_DIR" -maxdepth 1 \( -name '.injected-manifest-*.jsonl' -o -name '.verify-gate-blocks-*' -o -name '.verify-gate-agseen-*' -o -name '.critic-offer-*' \) -mtime +7 -exec rm -f {} + 2>/dev/null || true
fi

START_LINE=$((LAST_LINE + 1))
# The LLM input is capped at the newest 500 lines, but the substantive gate and
# the archive must cover the FULL delta — otherwise a >500-line turn silently
# drops its middle from both extraction and dream-mining (deep-review).
EXTRACT_START=$START_LINE
if [ "$NEW_LINES" -gt 500 ]; then
  EXTRACT_START=$((TOTAL_LINES - 500 + 1))
fi

# Substantive-session gate: count tool_use entries in the FULL delta.
TOOL_COUNT=$(sed -n "${START_LINE},${TOTAL_LINES}p" "$TRANSCRIPT" | jq -r '
  select(.type == "assistant")
  | .message.content[]?
  | select(.type == "tool_use")
  | .name
' 2>/dev/null | wc -l | tr -d ' ')

if [ "${TOOL_COUNT:-0}" -lt 1 ]; then
  TS_LINES=$NEW_LINES
  TS_FIRST_TYPE=$(sed -n "${START_LINE}p" "$TRANSCRIPT" 2>/dev/null | jq -r '.type // "no-type"' 2>/dev/null | tr -d '\n')
  log_gate "tool-count-zero lines=$TS_LINES first-type=$TS_FIRST_TYPE marker=$LAST_LINE"
  # Advance past the examined window: re-examining it next Stop can't find tools either.
  sb_set_extraction_marker "$MARKER_KEY" "$TOTAL_LINES"
  exit 0
fi

PROMPT_FILE="$(dirname "$0")/extract-prompt.txt"
if [ ! -f "$PROMPT_FILE" ]; then log_gate "prompt-file-missing path=$PROMPT_FILE"; exit 0; fi
PROMPT=$(cat "$PROMPT_FILE")

EXTRACT_INPUT=$(mktemp)
EXTRACT_OUT=$(mktemp)
trap 'rm -f "$EXTRACT_INPUT" "$EXTRACT_OUT" 2>/dev/null' EXIT
{
  echo "=== PROJECT.md ==="
  cat "$PROJECT_MD"
  echo
  echo "---SEPARATOR---"
  echo
  echo "=== TRANSCRIPT (preprocessed) ==="
  sed -n "${EXTRACT_START},${TOTAL_LINES}p" "$TRANSCRIPT" | sb_preprocess_transcript
} > "$EXTRACT_INPUT"

DELTA_JSON=""

# sb_call_extractor tries claude CLI then ANTHROPIC_API_KEY fallback, and
# writes a health marker to .extractor-health.json that session-load.sh
# reads to surface broken auth to the user on the next SessionStart.
if sb_call_extractor "$EXTRACT_INPUT" "$EXTRACT_OUT" "$EXTRACTOR_MODEL" "$PROMPT" "$EXTRACT_TIMEOUT"; then
  DELTA_JSON=$(cat "$EXTRACT_OUT")
else
  HEALTH_REASON=$(sb_get_extractor_health | jq -r '.reason // "unknown"' 2>/dev/null | tr -d '\r')
  sb_log_error "stop-extract.sh" "llm-extraction-failed model=$EXTRACTOR_MODEL output=$HEALTH_REASON" 0
fi

# Deterministic fallback when LLM is unavailable. Records a single [degraded] breadcrumb
# in a SIDECAR (`pending-extraction.log`), NOT in PROJECT.md's Recent decisions — those
# breadcrumbs are not decisions and were crowding real ones off the 5-bullet cap (SP-E).
# The transcript is still archived below, so the out-of-band drainer mines the REAL
# knowledge later; this sidecar just logs the gap. Deduped per day, bounded.
if [ -z "$DELTA_JSON" ]; then
  TODAY=$(date -u +%Y-%m-%d)
  PENDING_LOG="$(dirname "$PROJECT_MD")/pending-extraction.log"
  if grep -qF "[$TODAY] [degraded]" "$PENDING_LOG" 2>/dev/null; then
    # Already logged the breadcrumb today; still emit the deterministic delta — the files
    # changed in THIS session window are real and distinct (merge dedups + 5-bullet caps).
    DELTA_JSON=$(sb_extract_deterministic "$TRANSCRIPT" "$START_LINE" "$TOTAL_LINES")
  else
    # Scratch-path filter: /tmp, /var/tmp, /proc, /dev, /run are session-ephemeral
    # and have no value as future-session context — they only bloat the hot tier.
    FILES_JSON=$(sed -n "${START_LINE},${TOTAL_LINES}p" "$TRANSCRIPT" | jq -rcs '
      [
        .[]
        | select(.type == "assistant")
        | .message.content[]?
        | select(.type == "tool_use")
        | select(.name == "Edit" or .name == "Write" or .name == "MultiEdit")
        | .input.file_path
      ]
      | unique
      | map(select(. != null and . != ""))
      | map(select(test("^/tmp/|^/var/tmp/|^/proc/|^/dev/|^/run/") | not))
      | .[0:5]
    ' 2>/dev/null || echo '[]')
    FILES_JSON=$(sb_safe_json_array "$FILES_JSON")
    FILES_LIST=$(echo "$FILES_JSON" | jq -r 'join(", ")' 2>/dev/null | tr -d '\r')
    if [ -n "$FILES_LIST" ]; then
      NOTE="[degraded] LLM extraction unavailable; session touched: $FILES_LIST"
    else
      NOTE="[degraded] LLM extraction unavailable; tool-only session (transcript archived)"
    fi
    # Write the breadcrumb to the sidecar (out of PROJECT.md decisions), bounded to 50 lines.
    mkdir -p "$(dirname "$PENDING_LOG")" 2>/dev/null || true
    printf '[%s] %s\n' "$TODAY" "$NOTE" >> "$PENDING_LOG" 2>/dev/null || true
    if [ -f "$PENDING_LOG" ]; then
      tail -n 50 "$PENDING_LOG" > "$PENDING_LOG.tmp" 2>/dev/null && mv "$PENDING_LOG.tmp" "$PENDING_LOG" 2>/dev/null || rm -f "$PENDING_LOG.tmp" 2>/dev/null
    fi
    # Deterministic delta (P1): a grounded files-changed decision so capture reaches
    # PROJECT.md even with no LLM. The sidecar breadcrumb above stays the audit trail.
    DELTA_JSON=$(sb_extract_deterministic "$TRANSCRIPT" "$START_LINE" "$TOTAL_LINES")
  fi
fi

# Layer 4 Quality Gate — filter low-quality extractions before merging into PROJECT.md.
# On gate failure, pass through unchanged (fail open — never block a session-end extraction).
GATED_DELTA=$(printf '%s' "$DELTA_JSON" | bash "$(dirname "$0")/extraction-quality-gate.sh" 2>/dev/null)
if [ -n "$GATED_DELTA" ] && printf '%s' "$GATED_DELTA" | jq empty 2>/dev/null; then
  DELTA_JSON="$GATED_DELTA"
fi

MERGE_ERR=$(mktemp)
if ! echo "$DELTA_JSON" \
  | bash "$(dirname "$0")/merge-project-update.sh" \
      --project-md "$PROJECT_MD" --knowledge-dir "$KNOWLEDGE_DIR" >/dev/null 2>"$MERGE_ERR"; then
  ERR_TAIL=$(tr '\n' ' ' < "$MERGE_ERR" | head -c 400)
  log_gate "merge-failed err=$ERR_TAIL"
fi
rm -f "$MERGE_ERR"

# --- Relationship edges (typed, bi-temporal) ---
# Append any relations[] the extractor proposed to ~/knowledge/graph/edges.jsonl.
# Pure-bash + deterministic; best-effort — a failure here must never fail the
# Stop hook. Uses the same quality-gated $DELTA_JSON (the gate preserves the
# relations field, only filtering decisions/blockers/cross_refs).
echo "$DELTA_JSON" | bash "$(dirname "$0")/merge-edges.sh" --knowledge-dir "$KNOWLEDGE_DIR" 2>/dev/null || true

# --- Persona signal + rule-candidate extraction ---
# One payload object carries both extractor outputs: the merge script owns
# signal dedup/scoring AND candidate accumulation, so they must arrive together.
PERSONA_PAYLOAD=$(echo "$DELTA_JSON" | jq -c \
  '{persona_signals: (.persona_signals // []), rule_candidates: (.rule_candidates // [])}')
if echo "$PERSONA_PAYLOAD" | jq -e '(.persona_signals | length) + (.rule_candidates | length) > 0' >/dev/null 2>&1; then
  PERSONA_ERR=$(mktemp)
  if ! echo "$PERSONA_PAYLOAD" \
    | bash "$(dirname "$0")/merge-persona-signals.sh" 2>"$PERSONA_ERR"; then
    ERR_TAIL=$(tr '\n' ' ' < "$PERSONA_ERR" | head -c 200)
    log_gate "persona-merge-failed err=$ERR_TAIL"
  fi
  rm -f "$PERSONA_ERR"

  # Auto-pin-suggest: high-confidence signals route to .pin-candidates.jsonl
  # for the session-load.sh banner. Lower-confidence still go through the
  # graduation counter in merge-persona-signals.sh.
  echo "$PERSONA_PAYLOAD" | jq -c '.persona_signals[] | select(.confidence == "high")' 2>/dev/null | while IFS= read -r sig; do
    TEXT=$(printf '%s' "$sig" | jq -r '.signal // empty' 2>/dev/null | tr -d '\r')
    [ -n "$TEXT" ] && sb_append_pin_candidate "$SLUG" "$TEXT"
  done
fi

# --- Sessions digest (P0 rec 4): pushed continuity for the next SessionStart ---
# Deterministic post-extraction append; the helper replaces the same-session
# entry (Stop fires per turn) and skips when both fields are empty (degraded
# deltas carry neither — the drainer appends later from the real extraction).
DG_GOAL=$(echo "$DELTA_JSON" | jq -r '.session_goal // ""' 2>/dev/null | tr -d '\r')
DG_OUT=$(echo "$DELTA_JSON" | jq -r '.session_outcome // ""' 2>/dev/null | tr -d '\r')
sb_append_session_digest "$SLUG" "$SESSION_ID" "$DG_GOAL" "$DG_OUT" || true

# --- Archive preprocessed transcript for dream mining ---
sb_archive_transcript "$TRANSCRIPT" "$SLUG" "$SESSION_ID" "$START_LINE" "$TOTAL_LINES" "$TOOL_COUNT" 2>/dev/null || true

# --- Incremental episodic index update ---
PLUGIN_DIST="$(dirname "$0")/../mcp/dist/tools"
if command -v node >/dev/null 2>&1 && [ -f "$PLUGIN_DIST/episodic-index-cli.bundle.js" ]; then
  BRAIN_DIR="$BRAIN_DIR" node "$PLUGIN_DIST/episodic-index-cli.bundle.js" 2>/dev/null &
fi

rm -f "$BRAIN_DIR/.session-baseline-$SLUG.md"
sb_set_extraction_marker "$MARKER_KEY" "$TOTAL_LINES"

exit 0
