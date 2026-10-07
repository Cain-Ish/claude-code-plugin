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
#   SB_EXTRACT=off      — kill switch: skip the LLM extraction call entirely (no
#                        API spend). The transcript window is still archived and
#                        the marker still advances — a deterministic files-touched
#                        delta merges instead, same as an LLM failure would produce.
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
# Foreign headless child (`claude -p` / SDK-cli, nobody attending; R1#2): its transcript is neither
# archived nor extracted; the skip writes one gate=headless-child audit row and nothing else. Before
# the EXIT trap and the stdin read below. SB_HEADLESS_CONTEXT=on opts a run back in.
sb_is_headless_child && { sb_headless_trace stop-extract; exit 0; }

# Hook trace tag — set by each gate before exit, written by EXIT trap. Lets
# the next /second-brain:status surface exactly which gate the script tripped.
SB_GATE=""
log_gate() { SB_GATE="$1"; }
# D177: ONE cleanup function for the whole script's EXIT trap. bash keeps only the
# LAST `trap ... EXIT` registered — a second `trap ... EXIT` set later (e.g. the
# temp-file cleanup once EXTRACT_INPUT/EXTRACT_OUT exist) silently REPLACES this
# one, so every log_gate() call after that point (merge-failed, persona-merge-
# failed) would set SB_GATE with nothing left to write it. Anything else this
# script needs to run at exit must be added to this one function, never a bare
# `trap ... EXIT` elsewhere.
_sb_stop_extract_cleanup() {
  [ -n "$SB_GATE" ] && sb_log_error "stop-extract.sh" "gate=$SB_GATE" 0
  rm -f "${EXTRACT_INPUT:-}" "${EXTRACT_OUT:-}" 2>/dev/null
  # Telemetry scratch dir (subagent/window slices): normally removed at the end of the
  # telemetry block; this covers a crash inside it.
  [ -n "${SE_SCR:-}" ] && rm -rf "$SE_SCR" 2>/dev/null
}
trap _sb_stop_extract_cleanup EXIT

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
  # <<<-bounded: the only expansions are the slug (a directory name the mkdir above just made, so <= 255 B) and a timestamp over a ~650 B fixed template; an expanded heredoc of ~65,537..65,651 B blocks for good on MSYS
  cat > "$PROJECT_MD" <<TMPL
# PROJECT: $SLUG

## Goal
(auto-scaffolded — describe this project's goal)

## Direction
(goal · non-goals · priorities through YYYY-MM-DD — edit or run /second-brain:setup)

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

# --- Archive-first (0.56.0, R2#2) ---
# Append the raw window (raw_line cursor, TOTAL_LINES] to the session archive NOW: before the
# no-new-lines and tool-count gates, telemetry, JIT and the merge. Every window reaches the
# archive, tool-count-zero windows too (they hold the human reasoning), and an append that failed
# last time is retried even when this Stop has no new extraction window. The archive keeps its
# own cursor (.last-archived-line-*, shared with pre-compact.sh), so a merge-failed retry of the
# extraction window below never re-appends it. Failures are logged inside the helper; fail-soft.
sb_archive_raw_window "$TRANSCRIPT" "$SLUG" "$SESSION_ID" "$TOTAL_LINES" "$MARKER_KEY" || true

NEW_LINES=$((TOTAL_LINES - LAST_LINE))

if [ "$NEW_LINES" -lt 1 ]; then
  log_gate "no-new-lines marker=$LAST_LINE total=$TOTAL_LINES"
  exit 0
fi

# --- Loop telemetry (utilization / value / compounding) — OBSERVATION ONLY ---
# Machine-locked by mcp/src/telemetry-firewall.test.ts: nothing here may ever feed
# ranking/forgetting. Gated on the session's injection manifest (written by
# session-load.sh AND persona-context.sh via lib.sh's single-source sb_manifest_add).
# The manifest is CUMULATIVE for the whole session — it is never deleted here — so a
# later Stop's fresh injections (persona-context fires every prompt) are still
# counted. Each Stop scans ONLY its own new-lines window (same disjoint-window
# discipline as extraction, via LAST_LINE) and MERGES the window's findings into a
# per-session state file (.value-loop-state-$MANIFEST_SID.json: cumulative hit-id /
# ritual-id sets, pulled/agents counters, tiers map, turn count), so a metric that
# depends on "was this ever read across the whole session" survives across Stops
# without re-scanning transcript history already covered by an earlier Stop. Emits
# ONE `gate=value-loop` row PER STOP with the running totals; a reader takes the LAST
# row per sid as the session total (see docs/daily-prompt.md). Deterministic jq only —
# no LLM, transcript is DATA. Fail-soft: a telemetry error must never fail the hook.
#
# Millisecond clock into _SE_MS (same helper as hook-timer.sh): bash 5's $EPOCHREALTIME with
# no spawn; GNU date %N elsewhere; BSD/macOS date prints a literal N -> whole seconds.
_se_now_ms() {
  local n
  if [ -n "${EPOCHREALTIME:-}" ]; then
    n="${EPOCHREALTIME//[!0-9]/}"
    _SE_MS=$(( 10#$n / 1000 ))
    return 0
  fi
  n=$(date +%s%N 2>/dev/null)
  case "$n" in
    *N|*n|'') _SE_MS=$(( $(date +%s) * 1000 )) ;;
    *) _SE_MS=$(( n / 1000000 )) ;;
  esac
}
SE_SCR=""
if [ "${SB_TELEMETRY:-on}" != "off" ]; then
  MANIFEST_SID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9_-' | head -c 64)
  MANIFEST="$BRAIN_DIR/.injected-manifest-$MANIFEST_SID.jsonl"
  STATE_FILE="$BRAIN_DIR/.value-loop-state-$MANIFEST_SID.json"
  HC_STATE="$BRAIN_DIR/.hook-cancelled-state-$MANIFEST_SID.json"
  SUB_MARK="$BRAIN_DIR/.subagent-scan-mark-$MANIFEST_SID"
  SUB_MARK_WF="$BRAIN_DIR/.subagent-scan-mark-wf-$MANIFEST_SID"   # the workflows/ layer's own mark
  if [ -n "$MANIFEST_SID" ]; then
    _se_now_ms; SE_T0=$_SE_MS
    # --rawfile-safe path: --rawfile errors on a missing file, so a not-yet-created
    # state/scratch file must resolve to /dev/null (empty content), same fallback
    # pattern as buddy-statusline.sh's `_f` helper.
    _tel_f() { [ -f "$1" ] && printf '%s' "$1" || printf '%s' /dev/null; }
    # SE_OK=1: the scratch dir, the state read and the slicer below all succeeded, so the
    # value-loop and hook-cancelled passes may run AND commit their watermarks this Stop.
    # Any failure is logged loudly and leaves every watermark where it was (the next Stop
    # retries the same window) — never a silent sub_read=0 / missing-row Stop.
    SE_OK=1; VL_COMMITTED=0; HC_COMMITTED=0; SUB_CAND=0; SUB_COMPLETE=1
    SE_SCR=$(mktemp -d 2>/dev/null) || SE_SCR=""
    if [ -z "$SE_SCR" ] || [ ! -d "$SE_SCR" ]; then
      SE_SCR=""; SE_OK=0
      sb_log_error "stop-extract.sh" "telemetry: mktemp -d failed; value-loop, hook-cancelled and subagent scans skipped this Stop (no watermark advanced) sid=$MANIFEST_SID" 1
    fi

    # Subagent transcripts (S0 B7 ruler extension, docs/concepts/2026-09-27-repo-brain-
    # concept.md §5 S0): a subagent that reads or fetches a manifested id is real JIT
    # delivery use the PARENT transcript alone never sees, and a PreToolUse cancellation
    # INSIDE a subagent is recorded only in the SUBAGENT's own transcript, never the
    # parent's (verified live: hook_cancelled attachments land in
    # `${TRANSCRIPT%.jsonl}/subagents/agent-*.jsonl`). A long session carries dozens of
    # these files and 100+ MB, so subagent text is NEVER held in a bash variable and an
    # unchanged file is never re-read (the old per-Stop full re-read + string concat cost
    # 47-120 s per Stop on 25 files / 42 MB, load-dependent, against a 45 s hook budget):
    #   1. Candidates: a builtin -nt test against $SUB_MARK, a mark file touched (as .new)
    #      BEFORE this Stop captures any line count and renamed into place only once both
    #      passes committed. A file not modified since the last complete scan STARTED is
    #      skipped with zero spawns; a write racing a scan lands after the mark, so it is
    #      re-examined next Stop (equal whole-second mtimes count as changed, not skipped).
    #   2. ONE `xargs wc -lc` over the candidates captures each file's complete-line count
    #      (newline count: a torn last line is left for the next Stop) and size.
    #   3. ONE awk (below) reads only lines (watermark, captured count] of each candidate,
    #      keeping just the `"tool_use"` lines (value-loop) and `"hook_cancelled"` lines
    #      (hook-cancelled ruler) into scratch files. Per-file line watermarks for BOTH
    #      passes live in their state files (.sub_scanned: {basename: lines}).
    #   4. An aggregate byte cap (SB_SUBAGENT_SCAN_MAX_BYTES, default 256 MiB) bounds the
    #      read: files past it are skipped with a LOUD error row, their watermarks and the
    #      mark stay put, and the next Stop resumes with them.
    #   5. Workflow subagents write one level deeper, subagents/workflows/wf_<id>/agent-*.jsonl
    #      (DA #4, 0.54.1: 6,711 of this box's hook_cancelled records sat there, 3,354 of them
    #      PreToolUse — none ever counted: a `*` never crosses '/'). Watermark keys are the path
    #      RELATIVE to subagents/, so a flat file keeps its old basename key (no re-count) and
    #      two workflows' agent-X.jsonl cannot collide. The deeper layer has its own mark,
    #      written only by a scan that included it: an older mark predates every deep file this
    #      code never read, and would have skipped them for good.
    SUBAGENTS_DIR="${TRANSCRIPT%.jsonl}/subagents"
    SUB_CAP="${SB_SUBAGENT_SCAN_MAX_BYTES:-268435456}"
    case "$SUB_CAP" in ''|*[!0-9]*) SUB_CAP=268435456 ;; esac
    if [ "$SE_OK" = "1" ] && [ -d "$SUBAGENTS_DIR" ]; then
      if ! : > "$SUB_MARK.new" 2>/dev/null; then
        SUB_COMPLETE=0
        sb_log_error "stop-extract.sh" "subagent-scan: cannot write $SUB_MARK.new; changed-file detection falls back to re-counting every subagent file sid=$MANIFEST_SID" 1
      fi
      for _sub_f in "$SUBAGENTS_DIR"/agent-*.jsonl "$SUBAGENTS_DIR"/workflows/*/agent-*.jsonl; do
        [ -f "$_sub_f" ] || continue
        case "$_sub_f" in
          "$SUBAGENTS_DIR"/workflows/*) _sub_m="$SUB_MARK_WF" ;;
          *) _sub_m="$SUB_MARK" ;;
        esac
        [ -f "$_sub_m" ] && [ "$_sub_m" -nt "$_sub_f" ] && continue
        SUB_CAND=$((SUB_CAND + 1))
        printf '%s\0' "$_sub_f"
      done > "$SE_SCR/cand"
      if [ "$SUB_CAND" -gt 0 ]; then
        xargs -0 wc -lc < "$SE_SCR/cand" > "$SE_SCR/wc" 2> "$SE_SCR/wc.err"
        _se_rc=$?
        if [ "$_se_rc" -ne 0 ]; then
          SUB_COMPLETE=0
          sb_log_error "stop-extract.sh" "subagent-scan: wc over $SUB_CAND file(s) exited $_se_rc: $(head -c 200 "$SE_SCR/wc.err" 2>/dev/null | tr -d '\r\n') sid=$MANIFEST_SID" 1
        fi
      fi
    fi

    # ONE jq reads both per-sid states (tolerant: raw text, try/fromjson) and prints
    # status + scanned_to for each, then the per-file subagent watermarks as tagged TSV
    # (V = value-loop, H = hook-cancelled) for the slicer. Telemetry has its OWN
    # watermarks, independent of the extraction marker (.last-extracted-line-*): that
    # marker can be skipped-not-advanced (merge-failed, a killed extractor) or advanced
    # with no telemetry fold at all (pre-compact.sh), and trusting it re-counts.
    TEL_FROM=0; HC_FROM=0
    if [ "$SE_OK" = "1" ]; then
      jq -n -r --rawfile vs "$(_tel_f "$STATE_FILE")" --rawfile hs "$(_tel_f "$HC_STATE")" '
        def st($raw): if ($raw | length) == 0 then {s: "absent", v: {}}
          else ((try ($raw | fromjson) catch null) as $p
            | if ($p | type) == "object" then {s: "ok", v: $p} else {s: "corrupt", v: {}} end) end;
        def wm: if type == "number" and . >= 0 then floor else 0 end;
        def subs($tag): (.sub_scanned // {}) | if type == "object" then
            (to_entries[] | select((.key | test("^[^\t\r\n]+$")) and (.value | type) == "number")
              | "\($tag)\t\(.key)\t\(.value | wm)")
          else empty end;
        (st($vs)) as $v | (st($hs)) as $h |
        $v.s, ($v.v.scanned_to | wm), $h.s, ($h.v.scanned_to | wm), ($v.v | subs("V")), ($h.v | subs("H"))
      ' > "$SE_SCR/states" 2> "$SE_SCR/states.err"
      _se_rc=$?
      if [ "$_se_rc" -ne 0 ]; then
        SE_OK=0
        sb_log_error "stop-extract.sh" "telemetry: state read jq exited $_se_rc ($(head -c 200 "$SE_SCR/states.err" 2>/dev/null | tr -d '\r\n')); value-loop/hook-cancelled skipped, no watermark advanced sid=$MANIFEST_SID" 1
      fi
    fi
    if [ "$SE_OK" = "1" ]; then
      VL_ST=""; HC_ST=""
      { IFS= read -r VL_ST; IFS= read -r TEL_FROM; IFS= read -r HC_ST; IFS= read -r HC_FROM; } < "$SE_SCR/states"
      VL_ST="${VL_ST%$'\r'}"; TEL_FROM="${TEL_FROM%$'\r'}"; HC_ST="${HC_ST%$'\r'}"; HC_FROM="${HC_FROM%$'\r'}"
      case "$TEL_FROM" in ''|*[!0-9]*) TEL_FROM=0 ;; esac
      case "$HC_FROM" in ''|*[!0-9]*) HC_FROM=0 ;; esac
      # A PRESENT-but-unparseable state file is a torn/corrupt write (crash mid-mv, killed
      # hook, cross-filesystem copy+unlink), never "no prior state" — silently resetting
      # it to {} would zero every cumulative counter (or re-emit every hook-cancelled row)
      # with nothing logged. Quarantine loudly; the pass then starts from an empty state.
      if [ "$VL_ST" = "corrupt" ]; then
        sb_log_error "stop-extract.sh" "telemetry: value-loop state unparseable, quarantined sid=$MANIFEST_SID" 1
        mv -f "$STATE_FILE" "$STATE_FILE.corrupt" 2>/dev/null
        TEL_FROM=0
      fi
      if [ "$HC_ST" = "corrupt" ]; then
        sb_log_error "stop-extract.sh" "hook-cancelled: state unparseable, quarantined (counts restart from line 0) sid=$MANIFEST_SID" 1
        mv -f "$HC_STATE" "$HC_STATE.corrupt" 2>/dev/null
        HC_FROM=0
      fi
      # Stale watermark (transcript shrank / file replaced): clamp to 0 instead of hanging.
      [ "$TEL_FROM" -gt "$TOTAL_LINES" ] && TEL_FROM=0
      [ "$HC_FROM" -gt "$TOTAL_LINES" ] && HC_FROM=0

      # The slicer: ONE awk, ONE bounded pass over the parent (lines min(TEL_FROM,HC_FROM)+1
      # .. TOTAL_LINES, never past the count captured at the top of this script — a line
      # appended mid-Stop is left for the next Stop instead of being counted now AND again
      # then) plus the candidate subagent files (bounded by their wc counts, see above).
      # Outputs (scratch files): par_vl + sub_vl (tool_use lines), hc_in (hook_cancelled
      # lines), subwm ("key<TAB>lines" for every file whose new lines were taken; key = the
      # path relative to subagents/, which for a flat file is its basename);
      # stdout: K (byte-cap skip) / X (unreadable) / XP (parent unreadable) rows. Paths come
      # from ENVIRON and file data, never `awk -v` (Windows backslashes).
      [ -f "$SE_SCR/wc" ] || : > "$SE_SCR/wc"
      SE_TX="$TRANSCRIPT" SE_DIR="$SE_SCR" SE_SUBDIR="$SUBAGENTS_DIR" awk -v tf="$TEL_FROM" -v hf="$HC_FROM" -v tot="$TOTAL_LINES" -v cap="$SUB_CAP" '
        BEGIN {
          d = ENVIRON["SE_DIR"]
          parvl = d "/par_vl"; subvl = d "/sub_vl"; hcin = d "/hc_in"; subwm = d "/subwm"
          sd = ENVIRON["SE_SUBDIR"] "/"
        }
        { sub(/\r$/, "") }
        FILENAME == ARGV[1] {
          if (split($0, f, "\t") == 3) {
            if (f[1] == "V") vw[f[2]] = f[3] + 0
            else if (f[1] == "H") hw[f[2]] = f[3] + 0
          }
          next
        }
        {
          if (!match($0, /^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]/)) next
          p = substr($0, RLENGTH + 1)
          if (p == "total") next
          nf++; fp[nf] = p; flc[nf] = $1 + 0; fby[nf] = $2 + 0
        }
        END {
          lo = (tf < hf) ? tf : hf
          if (lo < tot) {
            tx = ENVIRON["SE_TX"]; n = 0; r = 1
            while (n < tot && (r = (getline line < tx)) > 0) {
              n++
              if (n <= lo) continue
              if (n > tf && index(line, "\"tool_use\"")) print line > parvl
              if (n > hf && index(line, "\"hook_cancelled\"")) print line > hcin
            }
            close(tx)
            if (r < 0) print "XP\tparent\t0"
          }
          used = 0
          for (i = 1; i <= nf; i++) {
            b = fp[i]
            if (substr(b, 1, length(sd)) == sd) b = substr(b, length(sd) + 1); else sub(/.*[\/\\]/, "", b)
            lc = flc[i]
            v = (b in vw) ? vw[b] : 0
            h = (b in hw) ? hw[b] : 0
            if (v > lc) v = 0
            if (h > lc) h = 0
            s = (v < h) ? v : h
            if (s < lc) {
              if (used + fby[i] > cap) { print "K\t" b "\t" fby[i]; continue }
              used += fby[i]
              n = 0; r = 1
              while (n < lc && (r = (getline line < fp[i])) > 0) {
                n++
                if (n <= s) continue
                if (n > v && index(line, "\"tool_use\"")) print line > subvl
                if (n > h && index(line, "\"hook_cancelled\"")) print line > hcin
              }
              close(fp[i])
              if (r < 0) { print "X\t" b "\t0"; continue }
              lc = n
            }
            print b "\t" lc > subwm
          }
        }
      ' "$SE_SCR/states" "$SE_SCR/wc" > "$SE_SCR/slice" 2> "$SE_SCR/slice.err"
      _se_rc=$?
      if [ "$_se_rc" -ne 0 ]; then
        SE_OK=0
        sb_log_error "stop-extract.sh" "telemetry: slicer awk exited $_se_rc ($(head -c 200 "$SE_SCR/slice.err" 2>/dev/null | tr -d '\r\n')); value-loop/hook-cancelled skipped, no watermark advanced sid=$MANIFEST_SID" 1
      fi
    fi
    if [ "$SE_OK" = "1" ] && [ -s "$SE_SCR/slice" ]; then
      _sk_n=0; _sk_b=0; _sk_1=""; _sx_n=0; _sx_1=""
      while IFS=$'\t' read -r _se_t _se_b _se_v; do
        case "$_se_v" in ''|*[!0-9]*) _se_v=0 ;; esac
        case "$_se_t" in
          K) _sk_n=$((_sk_n + 1)); _sk_b=$((_sk_b + _se_v)); [ -n "$_sk_1" ] || _sk_1="$_se_b" ;;
          X) _sx_n=$((_sx_n + 1)); [ -n "$_sx_1" ] || _sx_1="$_se_b" ;;
          XP) SE_OK=0 ;;
        esac
      done < "$SE_SCR/slice"
      if [ "$SE_OK" != "1" ]; then
        sb_log_error "stop-extract.sh" "telemetry: parent transcript unreadable mid-scan; value-loop/hook-cancelled skipped, no watermark advanced sid=$MANIFEST_SID" 1
      fi
      if [ "$_sk_n" -gt 0 ]; then
        SUB_COMPLETE=0
        sb_log_error "stop-extract.sh" "subagent-scan: aggregate byte cap ${SUB_CAP}B reached; skipped $_sk_n subagent transcript(s) (${_sk_b}B, first $_sk_1): not scanned, watermarks kept, retried next Stop sid=$MANIFEST_SID" 1
      fi
      if [ "$_sx_n" -gt 0 ]; then
        SUB_COMPLETE=0
        sb_log_error "stop-extract.sh" "subagent-scan: $_sx_n subagent transcript(s) unreadable (first $_sx_1): watermarks kept sid=$MANIFEST_SID" 1
      fi
    fi

  if [ "$SE_OK" = "1" ] && [ "$TEL_FROM" -lt "$TOTAL_LINES" ]; then
    # Parent tool_use lines of this window, bounded by TOTAL_LINES (slicer output).
    TEL_PAR="$(_tel_f "$SE_SCR/par_vl")"
    # utilization: Skill + Agent/Task(subagent_type) invocations -> counts store.
    # D-bug 1: the dispatch tool was renamed Task -> Agent; matching only "Task" left
    # every agent dispatch uncounted here (a separate, session-scoped metric from the
    # agents=/tiers= fields below, which fold the SAME rename fix into the value-loop row).
    TEL_NAMES=$(jq -R -r '
      fromjson? | select(type=="object" and .type=="assistant")
      | (.message | objects | .content | arrays | .[] | objects | select(.type=="tool_use"))
      | if .name=="Skill" then ("skill:" + (.input.skill // "unknown"))
        elif .name=="Task" or .name=="Agent" then ("agent:" + (.input.subagent_type // "unknown"))
        else empty end
    ' "$TEL_PAR" 2>/dev/null | tr -d '\r')
    if [ -n "$TEL_NAMES" ]; then
      UTIL_JSON="$BRAIN_DIR/utilization-counts.json"
      # Key aging (state hygiene): the counts store is append-keyed and never shrank —
      # a skill/agent used once a year ago kept its row forever. After the fold, drop
      # entries whose last_used is older than 180 days. Cutoff via the cross-platform
      # date fallback (GNU -d twin of BSD -v). last_used is a full ISO timestamp, so a
      # date-only cutoff compares correctly lexicographically (prefix rule).
      UTIL_CUTOFF=$(date -u -v-180d +%Y-%m-%d 2>/dev/null \
        || date -u -d '180 days ago' +%Y-%m-%d 2>/dev/null || echo '1970-01-01')
      TEL_TMP="$SE_SCR/util.json"
      { [ -s "$UTIL_JSON" ] && cat "$UTIL_JSON" 2>/dev/null || echo '{}'; } \
        | jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg names "$TEL_NAMES" --arg cutoff "$UTIL_CUTOFF" '
            . as $base | reduce ($names | split("\n") | map(select(length>0)))[] as $n ($base;
              .[$n] = {count: ((.[$n].count // 0) + 1), last_used: $now})
            | with_entries(select(.value.last_used >= $cutoff))
          ' > "$TEL_TMP" 2>/dev/null \
        && mv "$TEL_TMP" "$UTIL_JSON" 2>/dev/null \
        || { rm -f "$TEL_TMP"; sb_log_error "stop-extract.sh" "telemetry: utilization fold failed (corrupt store? $UTIL_JSON)" 1; }
    fi

    # ONE jq call, reading the parent window's tool_use lines (TEL_PAR) plus the
    # manifest, prior state, subagent tool_use lines and new subagent watermarks via
    # --rawfile (never --argjson/--arg on their full content): a long session's manifest
    # (persona-context appends per PROMPT) or a Read-heavy turn's window can exceed
    # Windows' ~32K CreateProcess argv cap if passed as arguments. Every input is parsed
    # TOLERANTLY (raw-slurp + per-line try/catch, objects only): a Stop can read a
    # transcript mid-write, so one torn or non-object line must not abort the whole
    # pass (same philosophy as sb_count_torn_lines elsewhere). reads/fetch are derived
    # HERE (gsub normalizes backslashes) instead of being passed in as --arg text, for
    # the same argv-size reason.
    TEL_BIG=$(jq -c -R -s \
      --rawfile mraw "$(_tel_f "$MANIFEST")" \
      --rawfile sraw "$(_tel_f "$STATE_FILE")" \
      --rawfile subraw "$(_tel_f "$SE_SCR/sub_vl")" \
      --rawfile subwm "$(_tel_f "$SE_SCR/subwm")" \
      --argjson total "$TOTAL_LINES" '
      def jsonl: split("\n") | map(select(length>0) | (try fromjson catch null) | objects);
      def tus: .[] | select(.type=="assistant")
        | (.message | objects | .content | arrays | .[] | objects | select(.type=="tool_use"));
      (jsonl) as $lines |
      ($subraw | jsonl) as $sub_lines |
      ($mraw | split("\n") | map(select(length>0)) | map(try fromjson catch null)
        | map(select(. != null and type=="object" and (.id // "") != "" and (.kind // "") != ""))) as $mf |
      ($sraw | (try fromjson catch {})) as $old0 |
      (if ($old0 | type) == "object" then $old0 else {} end) as $old |
      # Per-file subagent watermarks this Stop advanced ("basename<TAB>lines" rows from the
      # slicer), merged over the stored map in new_state.sub_scanned below.
      ($subwm | split("\n") | map(sub("\r$"; "") | select(length>0) | split("\t")
        | select(length==2 and (.[1] | test("^[0-9]+$"))) | {key: .[0], value: (.[1] | tonumber)})
        | from_entries) as $sw |
      # An anchor id (the project-ritual seed) must never count as a push metric
      # under ANY other kind it also happens to be manifested under (real KB: a
      # project slug can be both the ritual anchor AND a plain wiki page id).
      ([ $mf[] | select(.kind=="anchor") | .id ] | unique) as $anchors |
      ([ $mf[] | .id ] | unique) as $all_ids |
      def nonanchor: select(.id as $i | ($anchors | index($i)) == null);
      ([ $lines | tus | select(.name=="Read") | (.input.file_path // empty) | strings | gsub("\\\\"; "/") ]) as $reads_arr |
      ([ $lines | tus | select((.name // "") | tostring | test("knowledge_fetch|knowledge_neighbors|code_neighbors"))
         | (.input.slug // .input.node // empty) | strings ]) as $fetch_arr |
      # Subagent counterparts of reads_arr/fetch_arr, extracted from the NEW subagent
      # tool_use lines (per-file watermarks: each line is seen by exactly one Stop; the
      # hit sets below are cumulative in the state, so nothing already counted is lost).
      ([ $sub_lines | tus | select(.name=="Read") | (.input.file_path // empty) | strings | gsub("\\\\"; "/") ]) as $sub_reads_arr |
      ([ $sub_lines | tus | select((.name // "") | tostring | test("knowledge_fetch|knowledge_neighbors|code_neighbors"))
         | (.input.slug // .input.node // empty) | strings ]) as $sub_fetch_arr |
      # $-parameters (bound VALUES, evaluated once at the call site) — NOT bare
      # filter parameters. A bare def with an unprefixed parameter re-evaluates that
      # parameter (re-runs the .id lookup) against whatever the input is at each use
      # site inside the body (here, a string from reads_arr/fetch_arr) and blows up
      # with a string-indexing error. dollar-prefixed params bind once, correctly.
      def codemap_hit_in($id; $ra; $fa): ( ($ra | any(. as $r | $r | contains($id))) or ($fa | any(. as $f | $f | contains($id))) );
      def wiki_hit_in($id; $ra; $fa): ( ($fa | any(. == $id)) or ($ra | any(. as $r | $r | contains("/" + $id + ".md"))) );
      # read= (win_hit_ids) is the UNION of parent-window and subagent evidence; the
      # *_sub variants below are subagent-ONLY, used for the separate sub_read= count.
      def codemap_hit($id): codemap_hit_in($id; $reads_arr; $fetch_arr) or codemap_hit_in($id; $sub_reads_arr; $sub_fetch_arr);
      def wiki_hit($id): wiki_hit_in($id; $reads_arr; $fetch_arr) or wiki_hit_in($id; $sub_reads_arr; $sub_fetch_arr);
      def codemap_hit_sub($id): codemap_hit_in($id; $sub_reads_arr; $sub_fetch_arr);
      def wiki_hit_sub($id): wiki_hit_in($id; $sub_reads_arr; $sub_fetch_arr);
      {
        win_hit_ids:     ([ $mf[] | select(.kind != "anchor") | nonanchor | select(if .kind == "codemap" then codemap_hit(.id) else wiki_hit(.id) end) | .id ] | unique),
        win_sub_hit_ids: ([ $mf[] | select(.kind != "anchor") | nonanchor | select(if .kind == "codemap" then codemap_hit_sub(.id) else wiki_hit_sub(.id) end) | .id ] | unique),
        win_ritual_ids:  ([ $mf[] | select(.kind == "anchor") | select(wiki_hit(.id)) | .id ] | unique)
      } as $hits |
      ([ $lines | tus | select(.name | type == "string") ]) as $tu |
      {
        # pulled= is "pulls Claude makes on its own initiative", counted apart from
        # the ritual anchor fetch (ritual=) and from reads of already-injected ids
        # (read=). knowledge_search/episodic_*/code_map have no target id and always
        # count; a targeted fetch/neighbors call only counts if its target is NOT
        # something already manifested (anchor or otherwise) — that fetch is either
        # the ritual call or a read= hit, never both a pull AND one of those.
        pulled_win: ([ $tu[] | select(.name | test("knowledge_(search|fetch|neighbors)|episodic_(search|read)|code_(map|neighbors)"))
                       | select(
                           (.name | test("knowledge_search|episodic_(search|read)|code_map"))
                           or (((.input.slug // .input.node // "") as $t | ($t == "" or ($all_ids | index($t)) == null)))
                         ) ] | length),
        agents_win: ([ $tu[] | select(.name=="Agent" or .name=="Task") ] | length),
        tiers_win:  (reduce ( $tu[] | select(.name=="Agent" or .name=="Task") | (.input.model // "unset") ) as $m ({}; .[$m] = ((.[$m] // 0) + 1)))
      } as $tool |
      {
        new_state: {
          hit_ids:     ((($old.hit_ids // []) + $hits.win_hit_ids) | unique),
          sub_hit_ids: ((($old.sub_hit_ids // []) + $hits.win_sub_hit_ids) | unique),
          ritual_ids: ((($old.ritual_ids // []) + $hits.win_ritual_ids) | unique),
          pulled:     (($old.pulled // 0) + $tool.pulled_win),
          agents:     (($old.agents // 0) + $tool.agents_win),
          tiers:      (reduce ($tool.tiers_win | to_entries[]) as $e (($old.tiers // {}); .[$e.key] = ((.[$e.key] // 0) + $e.value))),
          turn:       (($old.turn // 0) + 1),
          scanned_to: $total,
          sub_scanned: ((($old.sub_scanned // {}) | if type == "object" then . else {} end) + $sw)
        }
      } as $merged |
      ($merged.new_state) as $ns |
      {
        # injected counts unique (kind,id) PAIRS (a slug injected under two kinds
        # counts twice); read counts unique IDS only (kind-agnostic) that landed in
        # the cumulative hit set — deliberate, not a bug: a kind-id double-injection
        # is still only ever "read" once. nonanchor drops an id that is ALSO
        # manifested as the anchor, regardless of which other kind carried it here.
        injected: ([ $mf[] | select(.kind != "anchor") | nonanchor | {kind, id} ] | unique | length),
        read:     ([ $mf[] | select(.kind != "anchor") | nonanchor | .id ] | unique | map(select(. as $i | $ns.hit_ids | index($i) != null)) | length),
        hits:     ([ $mf[] | select(.kind != "anchor") | nonanchor | .id ] | unique | map(select(. as $i | $ns.hit_ids | index($i) != null)) | map(gsub(" "; "%20"))),
        ritual:   ([ $mf[] | select(.kind == "anchor") | .id ] | unique | map(select(. as $i | $ns.ritual_ids | index($i) != null)) | length),
        prior_candidates: ([ $mf[] | select(.kind != "anchor") | nonanchor | select(.kind=="wiki" or .kind=="graph") | .id ] | unique | map(select(. as $i | $ns.hit_ids | index($i) != null))),
        agents: $ns.agents, pulled: $ns.pulled, turn: $ns.turn,
        tiers:  ($ns.tiers | to_entries | map("\(.key):\(.value)") | join(",")),
        # sub_read= (trailing field, S0 B7 ruler extension): count of manifested,
        # non-anchor ids ever hit via SUBAGENT evidence specifically — a subset of
        # read=, reported separately so the ruler can see how much of the union came
        # from a dispatched agent instead of the parent transcript.
        sub_read: ([ $mf[] | select(.kind != "anchor") | nonanchor | .id ] | unique | map(select(. as $i | $ns.sub_hit_ids | index($i) != null)) | length),
        new_state: $ns
      }
    ' "$TEL_PAR" 2>/dev/null | tr -d '\r')

    if [ -z "$TEL_BIG" ]; then
      sb_log_error "stop-extract.sh" "telemetry: value-loop jq pipeline failed (corrupt manifest/state?) sid=$MANIFEST_SID" 1
    else
      NEW_STATE_JSON=$(printf '%s' "$TEL_BIG" | jq -c '.new_state' 2>/dev/null | tr -d '\r')
      if [ -n "$NEW_STATE_JSON" ]; then
        # Temp file NEXT TO the target (same directory => same filesystem => the mv
        # below is an atomic rename, not $TMPDIR's cross-filesystem copy+unlink that
        # a killed hook can tear mid-copy (the corrupt-state repro this guards).
        if TEL_STATE_TMP=$(mktemp "$STATE_FILE.XXXXXX" 2>/dev/null); then
          if printf '%s' "$NEW_STATE_JSON" > "$TEL_STATE_TMP" 2>/dev/null \
            && mv "$TEL_STATE_TMP" "$STATE_FILE" 2>/dev/null; then
            VL_COMMITTED=1
          else
            rm -f "$TEL_STATE_TMP"
            sb_log_error "stop-extract.sh" "telemetry: state write failed sid=$MANIFEST_SID" 1
          fi
        else
          sb_log_error "stop-extract.sh" "telemetry: mktemp failed, state not persisted sid=$MANIFEST_SID" 1
        fi
      else
        sb_log_error "stop-extract.sh" "telemetry: value-loop new_state extraction failed sid=$MANIFEST_SID" 1
      fi

      # One VALUE per line (not @tsv/IFS=tab-split): tab is an IFS-whitespace
      # character, so `IFS=$'\t' read` COLLAPSES consecutive tabs — whenever a
      # field between two others is empty (hits= is empty on the very common
      # read=0 case), every field after it silently shifts left one slot (hits
      # gets the tiers value, tiers gets the prior-candidate list, ...). A `read`
      # per LINE has no such collapsing: an empty line is still exactly one line.
      TEL_LINES=$(printf '%s' "$TEL_BIG" | jq -r '
        .injected, .read, .ritual, .agents, .pulled, .turn,
        (.hits | join(",")), .tiers, (.prior_candidates | join(",")), .sub_read
      ' 2>/dev/null | tr -d '\r')
      # Every field starts empty: a process substitution that fails to open never runs the reads,
      # and an unset TEL_HITS/TEL_TIERS below would abort the rest of the Stop under set -u.
      TEL_INJ="" TEL_HIT="" TEL_RITUAL="" TEL_AGENTS="" TEL_PULLED="" TEL_TURN=""
      TEL_HITS="" TEL_TIERS="" TEL_PRIOR_CAND="" TEL_SUB_READ=""
      {
        IFS= read -r TEL_INJ
        IFS= read -r TEL_HIT
        IFS= read -r TEL_RITUAL
        IFS= read -r TEL_AGENTS
        IFS= read -r TEL_PULLED
        IFS= read -r TEL_TURN
        IFS= read -r TEL_HITS
        IFS= read -r TEL_TIERS
        IFS= read -r TEL_PRIOR_CAND
        IFS= read -r TEL_SUB_READ
      # Process substitution, not `<<<` (RR-SF2): on MSYS a here-string of 65,536..~65,650 bytes
      # hangs past the reader's start. TEL_LINES' size tracks .prior_candidates (a joined list of
      # page names) and .hits, so a session with enough candidates could reach that width.
      } < <(printf '%s\n' "$TEL_LINES")
      case "$TEL_INJ" in ''|*[!0-9]*) TEL_INJ=0 ;; esac
      case "$TEL_HIT" in ''|*[!0-9]*) TEL_HIT=0 ;; esac
      case "$TEL_RITUAL" in ''|*[!0-9]*) TEL_RITUAL=0 ;; esac
      case "$TEL_AGENTS" in ''|*[!0-9]*) TEL_AGENTS=0 ;; esac
      case "$TEL_PULLED" in ''|*[!0-9]*) TEL_PULLED=0 ;; esac
      case "$TEL_TURN" in ''|*[!0-9]*) TEL_TURN=0 ;; esac
      case "$TEL_SUB_READ" in ''|*[!0-9]*) TEL_SUB_READ=0 ;; esac

      # prior: a hit on a wiki/graph page CREATED before today = prior-session
      # knowledge reused. Filesystem lookup (not expressible in jq), bounded to the
      # small set of ALREADY-hit wiki/graph ids (not the whole manifest/transcript).
      TEL_PRIOR=0
      TEL_TODAY=$(date -u +%Y-%m-%d)
      if [ -n "${TEL_PRIOR_CAND:-}" ]; then
        _tel_oldifs="$IFS"
        IFS=','
        for _tel_pid in $TEL_PRIOR_CAND; do
          IFS="$_tel_oldifs"
          [ -z "$_tel_pid" ] && continue
          _tel_pf=$(find "$KNOWLEDGE_DIR/wiki" -maxdepth 2 -name "$_tel_pid.md" 2>/dev/null | head -1)
          if [ -n "$_tel_pf" ]; then
            _tel_created=$(sed -n 's/^created:[[:space:]]*//p' "$_tel_pf" 2>/dev/null | head -1 | tr -d '\r"')
            [ -n "$_tel_created" ] && [ "$_tel_created" \< "$TEL_TODAY" ] && TEL_PRIOR=$((TEL_PRIOR + 1))
          fi
          IFS=','
        done
        IFS="$_tel_oldifs"
      fi

      # ec=0 gate= trace -> audit-log; ONE row per Stop (cumulative for the session).
      # Field order after hits= must stay APPENDED, never inserted — docs/daily-prompt.md's
      # extraction grep relies on it, and a reader takes the LAST row per sid as the total.
      # sub_read= is the newest trailing field (S0 B7 ruler ext.) — appended AFTER sid=,
      # never inserted earlier: sid values never contain whitespace, so a downstream
      # whitespace-field-split reader still finds "sid=..." as its own token regardless
      # of what comes after it. elapsed_ms= (appended after sub_read=) is the wall time
      # of this Stop's telemetry block so far (subagent scan + value-loop pass), so a
      # slow ruler shows up in the ruler itself before it can cost a killed Stop.
      _se_now_ms
      sb_log_error "stop-extract.sh" "gate=value-loop injected=$TEL_INJ read=$TEL_HIT prior=$TEL_PRIOR hits=${TEL_HITS:-none} ritual=$TEL_RITUAL pulled=$TEL_PULLED agents=$TEL_AGENTS tiers=${TEL_TIERS:-none} turn=$TEL_TURN sid=$MANIFEST_SID sub_read=$TEL_SUB_READ elapsed_ms=$((_SE_MS - SE_T0))" 0
    fi
  fi
  fi

  # --- Hook-cancellation ruler (B7, "the ruler cannot see delivery") — OBSERVATION
  # ONLY. docs/concepts/2026-09-27-repo-brain-concept.md §5 S0: a PreToolUse deny
  # hook that gets cancelled (timeout or interrupt) lets the tool run unguarded —
  # this is the ONLY place that number is visible today, and it is a safety defect,
  # not just a metric. No new hook: this reads `hook_cancelled` attachment records
  # already sitting in the SAME transcript this Stop already read, PLUS the ones
  # recorded only in a subagent's own transcript (a PreToolUse cancellation INSIDE a
  # dispatched agent never appears in the parent). The slicer above already put ONLY the
  # new `"hook_cancelled"` lines of both sources into $SE_SCR/hc_in (the substring filter
  # is the old grep precheck: the common all-empty Stop spawns no grouping jq at all). A
  # cumulative per-sid watermark for the parent (scanned_to) plus a per-file watermark for
  # subagents (sub_scanned, MERGED — files skipped this Stop keep their old entry) keeps a
  # later Stop from re-counting the same attachment record from either source.
  #
  # ONE jq groups + formats every row; its exit status is checked directly (no pipe to
  # mask it) and a failure is logged loudly WITHOUT advancing either watermark, so the
  # next Stop retries the same records. Per-record parsing is tolerant: a non-object
  # line, a torn line, a non-object attachment or wrong-typed fields drop or degrade
  # only that record, never the whole window.
  #   hook=   hookName (else hookEvent). script= the LAST `name.sh`/`name.js` in the
  #           command — past hook-timer.sh's wrapper, and without the quote/argument that
  #           follows (`protocol-guard.sh" pre`). No command at all (real PostToolUse
  #           cancellations carry only hookName/hookEvent) -> script=- and max_ms=-, keyed
  #           by the event name alone. Both tokens are then reduced to [A-Za-z0-9:._-] so
  #           a crafted command/hook name cannot inject its own ` count=0` into the row.
  #   kind=   timeout when the record says timedOut:true; other for every cancellation
  #           that does not (the no-command records carry no timedOut field — interrupts
  #           and aborted tool calls). BOTH are counted: either way the hook's verdict
  #           never reached the tool call.
  #   elapsed_ms= wall time of this Stop's telemetry block up to these rows.
  if [ -n "$MANIFEST_SID" ] && [ "$SE_OK" = "1" ] \
     && { [ "$HC_FROM" -lt "$TOTAL_LINES" ] || [ -s "$SE_SCR/subwm" ]; }; then
    HC_GROUP_OK=1
    if [ -s "$SE_SCR/hc_in" ]; then
      # '|' as the field delimiter: every field is a tok (reduced to [A-Za-z0-9:._-] below), a
      # kind word, a count or a number/"-", so no field can contain one. Not a tab: IFS-whitespace
      # chars COLLAPSE consecutive delimiters (the field-shift bug the value-loop row documents).
      # Not \001 either: bash 3.2 (macOS /bin/bash) uses \001 as its internal CTLESC quoting byte
      # and never splits on it, so the whole row landed in hook= (CI macOS lane, 0.54.1).
      jq -R -s -r '
        def tok: if type == "string" and length > 0 then gsub("[^A-Za-z0-9:._-]"; "_") else null end;
        [ split("\n")[] | select(length > 0) | (try fromjson catch null)
          | select(type == "object" and .type == "attachment")
          | .attachment | select(type == "object" and .type == "hook_cancelled")
          | ((.command | strings) // "") as $cmd
          | {
              hook: ((.hookName | tok) // (.hookEvent | tok) // "unknown"),
              script: (if $cmd == "" then "-"
                       else ((([$cmd | scan("[^/\\\\\" ]+\\.(?:sh|js)")] | last) // "unknown") | tok) // "unknown" end),
              kind: (if .timedOut == true then "timeout" else "other" end),
              ms: (.durationMs | if type == "number" then . else null end)
            }
        ] | group_by([.hook, .script, .kind]) | .[]
        | "\(.[0].hook)|\(.[0].script)|\(.[0].kind)|\(length)|\(([.[].ms | numbers] | max) // "-")"
      ' "$SE_SCR/hc_in" > "$SE_SCR/hc_rows" 2> "$SE_SCR/hc.err"
      _se_rc=$?
      if [ "$_se_rc" -ne 0 ]; then
        HC_GROUP_OK=0
        sb_log_error "stop-extract.sh" "hook-cancelled: grouping jq exited $_se_rc ($(head -c 200 "$SE_SCR/hc.err" 2>/dev/null | tr -d '\r\n')); watermarks NOT advanced, retried next Stop sid=$MANIFEST_SID" 1
      else
        _se_now_ms; HC_EL=$((_SE_MS - SE_T0))
        while IFS='|' read -r HC_HOOK HC_SCRIPT HC_KIND HC_COUNT HC_MAX; do
          HC_MAX="${HC_MAX%$'\r'}"
          [ -z "$HC_HOOK" ] && continue
          sb_log_error "stop-extract.sh" "gate=hook-cancelled hook=$HC_HOOK script=$HC_SCRIPT kind=$HC_KIND count=$HC_COUNT max_ms=$HC_MAX sid=${MANIFEST_SID:0:8} elapsed_ms=$HC_EL" 0
        done < "$SE_SCR/hc_rows"
      fi
    fi
    # Watermarks advance whenever the window was read cleanly, rows or not: "nothing
    # new this Stop" must still move them so the next Stop reads only genuinely new
    # lines. Temp file next to the target (same filesystem => atomic rename).
    if [ "$HC_GROUP_OK" = "1" ]; then
      if HC_TMP=$(mktemp "$HC_STATE.XXXXXX" 2>/dev/null); then
        if jq -n --rawfile hs "$(_tel_f "$HC_STATE")" --rawfile sw "$(_tel_f "$SE_SCR/subwm")" --argjson total "$TOTAL_LINES" '
            ((try ($hs | fromjson) catch {}) | if type == "object" then . else {} end) as $o |
            ($sw | split("\n") | map(sub("\r$"; "") | select(length>0) | split("\t")
              | select(length==2 and (.[1] | test("^[0-9]+$"))) | {key: .[0], value: (.[1] | tonumber)})
              | from_entries) as $new |
            {scanned_to: $total,
             sub_scanned: ((($o.sub_scanned // {}) | if type == "object" then . else {} end) + $new)}
          ' > "$HC_TMP" 2>/dev/null && mv "$HC_TMP" "$HC_STATE" 2>/dev/null; then
          HC_COMMITTED=1
        else
          rm -f "$HC_TMP"
          sb_log_error "stop-extract.sh" "hook-cancelled: state write failed sid=$MANIFEST_SID" 1
        fi
      else
        sb_log_error "stop-extract.sh" "hook-cancelled: mktemp failed, state not persisted sid=$MANIFEST_SID" 1
      fi
    fi
  fi

  # The subagent scan mark moves forward only when EVERY candidate was read and BOTH
  # passes committed their per-file watermarks; otherwise the next Stop re-examines the
  # same candidates (their watermarks make that a no-double-count retry).
  if [ -n "$SE_SCR" ] && [ -f "$SUB_MARK.new" ]; then
    if [ "$SUB_CAND" -gt 0 ] && [ "$SUB_COMPLETE" = "1" ] && [ "$VL_COMMITTED" = "1" ] && [ "$HC_COMMITTED" = "1" ]; then
      # The workflows/ mark takes the same instant: this scan read that layer too.
      { mv -f "$SUB_MARK.new" "$SUB_MARK" && touch -r "$SUB_MARK" "$SUB_MARK_WF"; } 2>/dev/null \
        || sb_log_error "stop-extract.sh" "subagent-scan: cannot move $SUB_MARK.new into place (or stamp $SUB_MARK_WF); unchanged files are re-counted next Stop sid=$MANIFEST_SID" 1
    else
      rm -f "$SUB_MARK.new"
    fi
  fi
  [ -n "$SE_SCR" ] && rm -rf "$SE_SCR"
  SE_SCR=""

  # --- Subagent-start-miss ruler (B2 residual) — OBSERVATION ONLY. Reads the
  # SubagentStart/end markers another implementer's hooks write to
  # $BRAIN_DIR/.injected/<sid>.subagent.tsv: `start\t<agent_id>` (before any process
  # starts) and `end\t<agent_id>\t<verdict>\t<reason>` (agent_id is "-" when the
  # dispatch tool didn't surface one — hook-timer.sh cannot log a kill without a
  # start marker). A start with no matching end is a counted miss. This file is the
  # single source of truth and is re-read IN FULL each Stop (never watermarked): the
  # counts below are recomputed from the file's current cumulative content, not
  # accumulated by this script, so re-reading it on a later Stop can never double
  # count — an unchanged file reproduces the same numbers, a grown file reproduces
  # the new true totals (identical "last row per sid wins" contract as value-loop).
  # Named agent_ids are tracked in an awk associative array (POSIX awk, not a bash
  # `declare -A` — unrelated to the bash-portability ban); anonymous ("-") starts/
  # ends are tracked as plain counters since they cannot be paired by identity.
  # The file is keyed by the SANITIZED sid ([A-Za-z0-9_-], <=64 chars) exactly as
  # protocol-guard.sh's pg_marker writes it — never the raw payload session_id, which
  # would miss the file (or walk out of .injected/) for any id outside that charset.
  SUBTSV="$BRAIN_DIR/.injected/$MANIFEST_SID.subagent.tsv"
  if [ -n "$MANIFEST_SID" ] && [ -f "$SUBTSV" ]; then
    SSM=$(awk -F'\t' '
      $1=="start" {
        starts++
        id = ($2=="" ? "-" : $2)
        if (id=="-") dash_start++; else started[id]=1
      }
      $1=="end" {
        id = ($2=="" ? "-" : $2)
        if (id=="-") dash_end++; else delete started[id]
      }
      END {
        miss=0
        for (k in started) miss++
        d = (dash_start+0) - (dash_end+0)
        if (d>0) miss+=d
        printf "%d\t%d\n", miss, starts+0
      }
    ' "$SUBTSV" 2>/dev/null)
    SSM_MISS=$(printf '%s' "$SSM" | cut -f1)
    SSM_STARTS=$(printf '%s' "$SSM" | cut -f2)
    case "$SSM_MISS" in ''|*[!0-9]*) SSM_MISS=0 ;; esac
    case "$SSM_STARTS" in ''|*[!0-9]*) SSM_STARTS=0 ;; esac
    sb_log_error "stop-extract.sh" "gate=subagent-start-miss count=$SSM_MISS starts=$SSM_STARTS sid=${MANIFEST_SID:0:8}" 0
  fi

  # GC stray per-session markers from sessions that never reached a Stop (7d, same
  # policy as the .injected/ memos). Covers the telemetry manifest + cumulative state,
  # the hook-cancelled watermark, the subagent scan mark, AND the three verify-gate
  # session markers (.verify-gate-blocks-*, .verify-gate-agseen-*, .critic-offer-*),
  # which are written per-session by stop-verify-gate.sh and were never swept. One
  # find, -o group. Deliberately quiet: GC of already-lost state.
  find "$BRAIN_DIR" -maxdepth 1 \( -name '.injected-manifest-*.jsonl' -o -name '.value-loop-state-*.json' -o -name '.hook-cancelled-state-*.json' -o -name '.subagent-scan-mark-*' -o -name '.verify-gate-blocks-*' -o -name '.verify-gate-agseen-*' -o -name '.critic-offer-*' \) -mtime +7 -exec rm -f {} + 2>/dev/null || true
fi

# Repo-brain JIT index freshness rebuild (Slice 2, docs/plans/2026-09-24-repo-brain.md §F) —
# placed AFTER the telemetry block above so a failure here can never lose the value-loop row.
# Independent of SB_TELEMETRY; gated by SB_JIT (off ⇒ no rebuild — matches pg_jit's own kill
# switch, so a session with delivery disabled doesn't pay to maintain an index nobody reads)
# AND by SB_PROTOCOL_GUARD (off ⇒ protocol-guard.sh's pg_jit reader is itself disabled, so
# rebuilding the index it alone consumes is pure wasted work every Stop).
# Bounded (sb_timeout) and fully fail-soft: never blocks or fails the Stop hook.
if [ "${SB_JIT:-on}" != "off" ] && [ "${SB_PROTOCOL_GUARD:-on}" != "off" ]; then
  JIT_SLUG=$(sb_session_slug "$SESSION_ID")
  if [ -n "$JIT_SLUG" ]; then
    JIT_IDX="$BRAIN_DIR/projects/$JIT_SLUG/jit-index.json"
    JIT_STALE=0
    if [ ! -f "$JIT_IDX" ]; then
      JIT_STALE=1
    elif find "$KNOWLEDGE_DIR/wiki" -name '*.md' -newer "$JIT_IDX" 2>/dev/null | head -1 | grep -q .; then
      JIT_STALE=1
    elif [ -f "$BRAIN_DIR/projects/$JIT_SLUG/PROJECT.md" ] && [ "$BRAIN_DIR/projects/$JIT_SLUG/PROJECT.md" -nt "$JIT_IDX" ]; then
      JIT_STALE=1
    fi
    if [ "$JIT_STALE" = "1" ] && command -v node >/dev/null 2>&1; then
      JIT_CLI="$(sb_plugin_root)/mcp/dist/tools/jit-index-cli.bundle.js"
      if [ -f "$JIT_CLI" ]; then
        JIT_ERR=$(mktemp 2>/dev/null) || JIT_ERR="/dev/null"
        if ! sb_timeout 8 node "$JIT_CLI" "$JIT_SLUG" "${CLAUDE_PROJECT_DIR:-$CWD}" >/dev/null 2>"$JIT_ERR"; then
          sb_log_error "stop-extract.sh" "jit-index-rebuild failed slug=$JIT_SLUG err=$(tail -c 300 "$JIT_ERR" 2>/dev/null | tr -d '\r\n')" 1
        fi
        [ "$JIT_ERR" != "/dev/null" ] && rm -f "$JIT_ERR" 2>/dev/null
      fi
    fi
  fi
fi

START_LINE=$((LAST_LINE + 1))
# The LLM input is capped at the newest 500 lines, but the substantive gate and
# the archive must cover the FULL delta — otherwise a >500-line turn silently
# drops its middle from both extraction and dream-mining (deep-review).
EXTRACT_START=$START_LINE
if [ "$NEW_LINES" -gt 500 ]; then
  EXTRACT_START=$((TOTAL_LINES - 500 + 1))
fi

# Substantive-session gate: count tool_use entries in the FULL delta. The buddy's end-of-turn
# buddy_react call is chat, not work: counting it would run the whole pipeline on every turn.
# Per-line parse (sb_window_tool_count): a record cut mid-write no longer hides the rest.
TOOL_COUNT=$(sb_window_tool_count "$TRANSCRIPT" "$START_LINE" "$TOTAL_LINES")

if [ "${TOOL_COUNT:-0}" -lt 1 ]; then
  TS_LINES=$NEW_LINES
  TS_FIRST_TYPE=$(sed -n "${START_LINE}p" "$TRANSCRIPT" 2>/dev/null | jq -r '.type // "no-type"' 2>/dev/null | tr -d '\r\n')
  log_gate "tool-count-zero lines=$TS_LINES first-type=$TS_FIRST_TYPE marker=$LAST_LINE"
  # Advance past the examined window: re-examining it next Stop can't find tools either.
  sb_set_extraction_marker "$MARKER_KEY" "$TOTAL_LINES"
  exit 0
fi

# C4/F3 (Slice 1 §5.1): stamp provenance NOW, right after the substantive gate confirms this
# window is real -- this is the ONLY in-session capture path for OAuth-only users, so it must
# never be skipped when the LLM call below fails or times out.
sb_session_prov_write "$SESSION_ID" "${CLAUDE_PROJECT_DIR:-$CWD}"

PROMPT_FILE="$(dirname "$0")/extract-prompt.txt"
if [ ! -f "$PROMPT_FILE" ]; then log_gate "prompt-file-missing path=$PROMPT_FILE"; exit 0; fi
PROMPT=$(cat "$PROMPT_FILE")

EXTRACT_INPUT=$(mktemp)
EXTRACT_OUT=$(mktemp)
# Cleanup for these two temp files is folded into _sb_stop_extract_cleanup (D177) —
# a second `trap ... EXIT` here would silently replace the gate-logging trap.
# Every part of the input is checked, as the drainer's sb_extract_transcript does (lib.sh): a
# render that failed (jq killed or missing, the scrub failed: sb_preprocess_transcript returns 1
# and its output must not be used) used to go out as PROJECT.md plus a cut or empty transcript and
# merged as a real extraction. Such an input is never sent; the deterministic floor runs instead.
EXTRACT_INPUT_OK=1
{
  echo "=== PROJECT.md ===" && cat "$PROJECT_MD" && echo && echo "---SEPARATOR---" && echo \
    && echo "=== TRANSCRIPT (preprocessed) ==="
} > "$EXTRACT_INPUT" || EXTRACT_INPUT_OK=0
sed -n "${EXTRACT_START},${TOTAL_LINES}p" "$TRANSCRIPT" | sb_preprocess_transcript >> "$EXTRACT_INPUT"
_ei_ps="${PIPESTATUS[*]}"
[ "$_ei_ps" = "0 0" ] || EXTRACT_INPUT_OK=0

DELTA_JSON=""

# sb_call_extractor tries claude CLI then ANTHROPIC_API_KEY fallback, and
# writes a health marker to .extractor-health.json that session-load.sh
# reads to surface broken auth to the user on the next SessionStart.
if [ "${SB_EXTRACT:-on}" = "off" ]; then
  log_gate "extract-off"
elif [ "$EXTRACT_INPUT_OK" != 1 ]; then
  sb_log_error "stop-extract.sh" "extractor input for raw lines ${EXTRACT_START}-${TOTAL_LINES} could not be built (render pipe status $_ei_ps); not sent to the extractor, deterministic floor instead (the archived window is mined later)" 1
elif sb_call_extractor "$EXTRACT_INPUT" "$EXTRACT_OUT" "$EXTRACTOR_MODEL" "$PROMPT" "$EXTRACT_TIMEOUT"; then
  DELTA_JSON=$(cat "$EXTRACT_OUT")
else
  HEALTH_REASON=$(sb_get_extractor_health | jq -r '.reason // "unknown"' 2>/dev/null | tr -d '\r')
  sb_log_error "stop-extract.sh" "llm-extraction-failed model=$EXTRACTOR_MODEL output=$HEALTH_REASON" 0
fi

# Deterministic fallback when the LLM is unavailable (sb_degraded_floor, lib.sh, shared with
# pre-compact.sh): the files-changed floor reaches PROJECT.md, and ONE [degraded] breadcrumb per
# day goes to the pending-extraction.log SIDECAR, never PROJECT.md's Recent decisions (SP-E). The
# transcript was archived above (archive-first), so the out-of-band drainer mines the REAL
# knowledge later.
if [ -z "$DELTA_JSON" ]; then
  DELTA_JSON=$(sb_degraded_floor "$TRANSCRIPT" "$START_LINE" "$TOTAL_LINES" "$PROJECT_MD")
fi

# Layer 4 Quality Gate (D157): shared with pre-compact.sh and the out-of-band
# drainer (sb_gate_extraction_delta, lib.sh) so every capture path filters
# low-quality extractions the same way. On gate failure, pass through
# unchanged (fail open — never block a session-end extraction).
DELTA_JSON=$(sb_gate_extraction_delta "$DELTA_JSON")

MERGE_ERR=$(mktemp)
MERGE_FAILED=0
if ! echo "$DELTA_JSON" \
  | bash "$(dirname "$0")/merge-project-update.sh" \
      --project-md "$PROJECT_MD" --knowledge-dir "$KNOWLEDGE_DIR" --session "$SESSION_ID" >/dev/null 2>"$MERGE_ERR"; then
  ERR_TAIL=$(tr '\n' ' ' < "$MERGE_ERR" | head -c 400)
  log_gate "merge-failed err=$ERR_TAIL"
  MERGE_FAILED=1
fi
rm -f "$MERGE_ERR"

# --- Relationship edges (typed, bi-temporal), D157 ---
# Shared with pre-compact.sh and the drainer (sb_merge_extraction_edges,
# lib.sh). Runs AFTER the merge above so relations[] endpoints can resolve
# against wiki stub pages merge-project-update.sh's cross_refs handling may
# have just scaffolded. Best-effort — a failure here must never fail the hook.
sb_merge_extraction_edges "$DELTA_JSON" "$KNOWLEDGE_DIR"

# --- Persona signal + rule-candidate extraction ---
# One payload object carries both extractor outputs: the merge script owns
# signal dedup/scoring AND candidate accumulation, so they must arrive together.
PERSONA_PAYLOAD=$(echo "$DELTA_JSON" | jq -c \
  '{persona_signals: (.persona_signals // []), rule_candidates: (.rule_candidates // [])}')
if echo "$PERSONA_PAYLOAD" | jq -e '(.persona_signals | length) + (.rule_candidates | length) > 0' >/dev/null 2>&1; then
  PERSONA_ERR=$(mktemp)
  if ! echo "$PERSONA_PAYLOAD" \
    | bash "$(dirname "$0")/merge-persona-signals.sh" --slug "$SLUG" 2>"$PERSONA_ERR"; then
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
if [ -n "$DG_GOAL$DG_OUT" ]; then
  sb_buddy_event "$SESSION_ID" remembered pleased "Filed to memory: ${DG_OUT:-$DG_GOAL}" stop-extract 1800
fi

# (The window was archived at the top, archive-first: sb_archive_raw_window.)

# --- Incremental episodic index update ---
# D179: the backgrounded index build must not inherit the hook's stdout. A reader of a pipe only
# sees EOF once every holder closes it, so Claude Code's read of this hook's JSON response could
# not close until the (unbounded, embeds-everything) index build finished. 0.56.0: the SUBSHELL's
# fds are redirected as well, not only node's: the waiting subshell held the pipe open just the
# same. Failures are fail-loud via sb_log_error (it writes files, not stdout).
PLUGIN_DIST="$(dirname "$0")/../mcp/dist/tools"
if command -v node >/dev/null 2>&1 && [ -f "$PLUGIN_DIST/episodic-index-cli.bundle.js" ]; then
  EIDX_LOG="$BRAIN_DIR/episodic-index.log"
  ( BRAIN_DIR="$BRAIN_DIR" node "$PLUGIN_DIST/episodic-index-cli.bundle.js" >>"$EIDX_LOG" 2>&1
    _eidx_ec=$?
    [ "$_eidx_ec" -ne 0 ] && sb_log_error "stop-extract.sh" "episodic-index-cli exited $_eidx_ec (see $EIDX_LOG)" "$_eidx_ec"
  ) </dev/null >/dev/null 2>&1 &
fi

rm -f "$BRAIN_DIR/.session-baseline-$SLUG.md"
# D177: a failed merge means this window's decisions never reached PROJECT.md —
# leave the marker where it is so the NEXT Stop retries the same window (a
# transient PROJECT.md issue should self-heal on retry) instead of being
# silently marked processed and lost forever.
[ "$MERGE_FAILED" = "1" ] || sb_set_extraction_marker "$MARKER_KEY" "$TOTAL_LINES"

exit 0
