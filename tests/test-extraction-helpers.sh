#!/bin/bash
# Tests for the lib.sh extraction helpers
# run-all-timeout: 360   (11 real extract->gate->merge passes; one pass is ~12s on the MSYS dev box; measured 91-164s)
# pins: SB_EXTRACT_MAX_BYTES — set per call to force 2 forward chunks on a small fixture (the chunking IS the behavior under test)
# pins: SB_TRANSCRIPT_CAP — the X2 S1/S2 eviction cases cap at 3 so a 4-archive fixture is over the cap
# pins: SB_SUBAGENT_ARCHIVE_CAP — the X2 S4 cases cap the subagent archives at 2 (soft) / 6 (hard) to exercise both passes
# shellcheck disable=SC2015  # `cond && ok || no`: ok/no always return 0, so || is never wrongly taken
# shellcheck disable=SC2317  # sb_call_extractor is overridden as a stub; reached indirectly via sb_extract_transcript
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export BRAIN_DIR="$SANDBOX/brain"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SANDBOX/knowledge"
mkdir -p "$BRAIN_DIR/projects" "$CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR/wiki"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
no()   { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || no "$1 — '$2' != '$3'"; }


echo "=== extraction helpers ==="

# --- sb_line_count: the one archive_line primitive (R2 contract) ---
LC="$SANDBOX/lc.txt"
eq "line_count: missing file is 0" "$(sb_line_count "$SANDBOX/absent.txt")" "0"
: > "$LC";                          eq "line_count: empty file is 0"           "$(sb_line_count "$LC")" "0"
printf 'a\nb\nc\n' > "$LC";         eq "line_count: three complete lines"      "$(sb_line_count "$LC")" "3"
printf 'a\nb\ntorn' > "$LC";        eq "line_count: a torn last line is not counted" "$(sb_line_count "$LC")" "2"
printf 'a\r\nb\r\n' > "$LC";        eq "line_count: CRLF lines count once each" "$(sb_line_count "$LC")" "2"

# --- slug from header ---
TX="$BRAIN_DIR/transcripts/sess1_my-proj_2026-05-24.txt"
mkdir -p "$BRAIN_DIR/transcripts"
cat > "$TX" <<'EOF'
--- session-meta ---
session_id: sess1
project_slug: my-proj
date: 2026-05-24
tool_count: 3
line_count: 10
---

USER: hello
ASSISTANT: hi
EOF
eq "slug from header" "$(sb_slug_from_archived_transcript "$TX")" "my-proj"

# --- extract one transcript (stub the LLM, run real merge) ---
sb_call_extractor() {  # stub: write a canned delta, succeed
  local out="$2"
  printf '{"recent_decisions":["drained test decision"],"open_blockers":[],"cross_refs":[],"files_touched":[],"persona_signals":[]}' > "$out"
  return 0
}
sb_extract_transcript "$TX" "my-proj" && ok "extract returns 0" || no "extract returns 0"
grep -q "drained test decision" "$BRAIN_DIR/projects/my-proj/PROJECT.md" \
  && ok "extract merged the delta into PROJECT.md" || no "extract merged the delta into PROJECT.md"

# --- D121: the drainer must use the archived header slug VERBATIM (same
# CR-strip/tmp-collapse as sb_slug_from_dir), not sb_sanitize_slug's
# lowercase/charset rewrite — else it writes a DIFFERENT project dir than the
# one already registered/written by the capture funnel for any slug with
# uppercase, '_' or '.' (the shipped monorepo `root__leaf` form included). ---
sb_call_extractor() {
  local out="$2"
  printf '{"recent_decisions":["drainer test decision"],"open_blockers":[],"cross_refs":[],"files_touched":[],"persona_signals":[]}' > "$out"
  return 0
}
sb_extract_transcript "$TX" "Mono__Api" >/dev/null 2>&1
[ -f "$BRAIN_DIR/projects/Mono__Api/PROJECT.md" ] \
  && ok "D121: verbatim slug Mono__Api resolves to projects/Mono__Api/" \
  || no "D121: Mono__Api did not land in projects/Mono__Api/ (sanitized elsewhere?)"
[ ! -d "$BRAIN_DIR/projects/mono-api" ] \
  && ok "D121: no split-brain sanitized sibling dir (mono-api) created" \
  || no "D121: split-brain sanitized sibling dir 'mono-api' was created"
grep -q "drainer test decision" "$BRAIN_DIR/projects/Mono__Api/PROJECT.md" 2>/dev/null \
  && ok "D121: delta merged into the verbatim-slug PROJECT.md" \
  || no "D121: delta not found in projects/Mono__Api/PROJECT.md"

# --- D121 edge: a bare "." or ".." header must not resolve outside projects/ ---
sb_extract_transcript "$TX" ".." >/dev/null 2>&1 || true
[ ! -e "$BRAIN_DIR/PROJECT.md" ] \
  && ok "D121: '..' slug rejected, no escape to BRAIN_DIR/PROJECT.md" \
  || no "D121: '..' slug escaped to BRAIN_DIR/PROJECT.md"

# --- security: a malicious project_slug must NOT escape BRAIN_DIR (path traversal) ---
EVIL_TARGET="/tmp/sb-pwned-$$/PROJECT.md"
rm -rf "/tmp/sb-pwned-$$" 2>/dev/null || true
sb_extract_transcript "$TX" "../../../../tmp/sb-pwned-$$" >/dev/null 2>&1 || true
[ ! -e "$EVIL_TARGET" ] && ok "traversal slug does not escape BRAIN_DIR" || no "traversal slug ESCAPED to $EVIL_TARGET"
rm -rf "/tmp/sb-pwned-$$" 2>/dev/null || true

# --- extract returns non-zero when the LLM yields nothing ---
sb_call_extractor() { : > "$2"; return 1; }
sb_extract_transcript "$TX" "my-proj" && no "extract fails on empty LLM" || ok "extract fails on empty LLM"

# --- DR-1 (Slice 1 §5.4): the drainer passes --session from the archive header, and a seeded
# .prov file makes the Handoff stamp reflect the ORIGINAL session's epoch (not drainer merge
# time) -- a back-dated handoff must not look fresh. ---
TX_DR1="$BRAIN_DIR/transcripts/sessDRAIN01_dr-proj_2026-05-24.txt"
cat > "$TX_DR1" <<'EOF'
--- session-meta ---
session_id: sessDRAIN01
project_slug: dr-proj
date: 2026-05-24
tool_count: 1
line_count: 5
---

USER: hello
ASSISTANT: hi
EOF
mkdir -p "$BRAIN_DIR/.injected"
printf '1789000000\tabc1234\tmain' > "$BRAIN_DIR/.injected/sessDRAIN01.prov"
sb_call_extractor() {
  local out="$2"
  printf '{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[],"handoff":{"in_flight":"dr-1 probe","failed_approaches":[],"pointers":[]}}' > "$out"
  return 0
}
sb_extract_transcript "$TX_DR1" "dr-proj" >/dev/null 2>&1
PROJ_DR="$BRAIN_DIR/projects/dr-proj/PROJECT.md"
DR1_STAMP=$(awk '/^## Handoff$/{f=1;next} /^## /{f=0} f && /^written: /{print; exit}' "$PROJ_DR")
case "$DR1_STAMP" in
  "written: t=1789000000 session=sessDRAI"*) ok "DR-1: drainer stamp uses the archive's .prov epoch (back-dated, not fresh)" ;;
  *) no "DR-1: unexpected stamp: $DR1_STAMP" ;;
esac

# --- DR-2: the drainer's merge call uses the SAME merge_plan carry guard as in-session capture
# -- an existing unfinished item the stub's plan omits is carried, not dropped. ---
printf '%s' '{"plan":["[ ] drainer-kept"]}' \
  | bash "$SCRIPT_DIR/merge-project-update.sh" --project-md "$PROJ_DR" --knowledge-dir "$CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR" >/dev/null 2>&1
sb_call_extractor() {
  local out="$2"
  printf '{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[],"plan":["[ ] a fresh drainer item"]}' > "$out"
  return 0
}
sb_extract_transcript "$TX_DR1" "dr-proj" >/dev/null 2>&1
grep -qE '^- \[ \] \[carried [0-9]{4}-[0-9]{2}-[0-9]{2}\] drainer-kept$' "$PROJ_DR" \
  && ok "DR-2: the drainer's merge carries an omitted unfinished item (same guard as in-session)" \
  || no "DR-2: drainer-kept was not carried (got: $(awk '/^## Plan$/{f=1;next} /^## /{f=0} f' "$PROJ_DR"))"

# --- DR-3: a subagent_result: true archive carries the PARENT's session id -- --session must
# NOT be passed, so the Handoff stamp has no session= token. ---
TX_DR3="$BRAIN_DIR/transcripts/sub-sessDRAIN01_dr-proj_2026-05-24.txt"
cat > "$TX_DR3" <<'EOF'
--- session-meta ---
session_id: sessDRAIN01
project_slug: dr-proj
subagent_result: true
date: 2026-05-24
tool_count: 1
line_count: 5
---

USER: hello
ASSISTANT: hi
EOF
sb_call_extractor() {
  local out="$2"
  printf '{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[],"handoff":{"in_flight":"dr-3 probe","failed_approaches":[],"pointers":[]}}' > "$out"
  return 0
}
sb_extract_transcript "$TX_DR3" "dr-proj" >/dev/null 2>&1
DR3_STAMP=$(awk '/^## Handoff$/{f=1;next} /^## /{f=0} f && /^written: /{print; exit}' "$PROJ_DR")
case "$DR3_STAMP" in
  *"session="*) no "DR-3: subagent archive stamp carries a session= token: $DR3_STAMP" ;;
  "written: t="*) ok "DR-3: subagent archive stamp carries no session= token" ;;
  *) no "DR-3: unexpected stamp: $DR3_STAMP" ;;
esac

# --- SF-M3: sb_session_prov_write fails LOUD on write-path errors, not silently -----------
ERRLOG="$BRAIN_DIR/error-log.jsonl"
: > "$ERRLOG"
sb_session_prov_write 'bad!sid' "$SANDBOX" || true
[ -f "$BRAIN_DIR/.injected/bad!sid.prov" ] && no "SF-M3: a bad-charset sid still wrote a .prov file" || ok "SF-M3: a bad-charset sid writes no .prov file"
grep -q 'sid failed the charset guard' "$ERRLOG" 2>/dev/null && ok "SF-M3: bad-sid charset failure logged loud" || no "SF-M3: bad-sid charset failure was silent"

: > "$ERRLOG"
rm -rf "$BRAIN_DIR/.injected" 2>/dev/null || true
touch "$BRAIN_DIR/.injected"   # a FILE at this path -- mkdir -p must fail, not silently no-op
sb_session_prov_write 'mkdirfailsid' "$SANDBOX" || true
grep -q 'mkdir .*\.injected failed' "$ERRLOG" 2>/dev/null && ok "SF-M3: mkdir failure logged loud" || no "SF-M3: mkdir failure was silent (got: $(cat "$ERRLOG" 2>/dev/null))"
rm -f "$BRAIN_DIR/.injected"
mkdir -p "$BRAIN_DIR/.injected"

: > "$ERRLOG"
sb_session_prov_write 'goodsid12345' "$SANDBOX" || true
[ -f "$BRAIN_DIR/.injected/goodsid12345.prov" ] && ok "SF-M3: a valid sid still writes .prov (no regression)" || no "SF-M3: a valid sid failed to write .prov"

# --- F2 (portability): sb_timeout's bash-watchdog fallback must not hold the caller open
# past the wrapped command's own real runtime. sb_timeout looks up its bounding binary via
# exactly `command -v timeout` / `command -v gtimeout` -- shadow ONLY that lookup with a
# function (real PATH untouched, so date/sleep/rm/the EXIT trap all keep working normally;
# no MSYS ln -s deep-copy risk, no risk of nuking the dir that also holds date/sleep).
command() {
  if [ "${1:-}" = "-v" ] && { [ "${2:-}" = "timeout" ] || [ "${2:-}" = "gtimeout" ]; }; then
    return 1
  fi
  builtin command "$@"
}
# Non-discriminating before: timing `sb_timeout 2 true` proves the CALLER returns fast, but
# `true` emits no stdout, so it never exercises the bug this fallback exists to catch (F2:
# the watchdog subshell inheriting the foreground command's stdout fd, so `$(sb_timeout ...)`
# blocks on that fd until the watchdog's own sleep expires even though the wrapped command
# already finished). Capture stdout AND time it: a watchdog that leaves stdout open would
# make F2_OUT correct (echo already flushed it) but F2_ELAPSED balloon to the full ~2s+
# watchdog lifetime.
F2_START=$(date +%s)
F2_OUT=$(sb_timeout 2 echo hi)
F2_END=$(date +%s)
unset -f command
F2_ELAPSED=$((F2_END - F2_START))
[ "$F2_OUT" = "hi" ] && ok "F2: bash-watchdog fallback preserves stdout ('$F2_OUT')" \
  || no "F2: bash-watchdog fallback stdout was '$F2_OUT', expected 'hi'"
[ "$F2_ELAPSED" -le 1 ] && ok "F2: bash-watchdog fallback returns fast (${F2_ELAPSED}s, not the full 2s+ bound)" \
  || no "F2: bash-watchdog fallback took ${F2_ELAPSED}s, expected <=1s"

# ==== R2-B (0.56.0) drain side: line cursor accounting, delta windows, source-scan lock ====
# Everything below exercises the R2 contract in lib.sh ("R2 contract"): the cursor is max(lines)
# over ok|baseline rows, retry/error rows never advance it, a legacy row without `lines` advances
# nothing, and an archive whose line count fell below its rows was recreated (cursor 0).
echo "=== R2-B: sb_drain_cursor_map ==="
MT="$SANDBOX/map-tx"; MS="$SANDBOX/map-state.jsonl"
mkdir -p "$MT"
mk_arch() {  # $1 = path, $2 = body line count, $3 = "crlf" for CRLF line ends. Header = 7 lines.
  local f="$1" n="$2" e=$'\n' i=1
  [ "${3:-}" = "crlf" ] && e=$'\r\n'
  {
    printf -- '--- session-meta ---%s' "$e"
    printf 'session_id: %s%s' "${f##*/}" "$e"
    printf 'project_slug: proj%s' "$e"
    printf 'date: 2026-05-24%s' "$e"
    printf 'tool_count: 1%s' "$e"
    printf 'line_count: %s%s' "$n" "$e"
    printf -- '---%s' "$e"
    while [ "$i" -le "$n" ]; do printf 'BODY-%02d%s' "$i" "$e"; i=$((i+1)); done
  } > "$f"
}
mf() {  # $1 = map text, $2 = basename, $3 = field number -> that TSV field ('' when absent)
  printf '%s\n' "$1" | awk -F'\t' -v b="$2" -v k="$3" '$1 == b { print $k; exit }'
}
mk_arch "$MT/a.txt" 3                                   # 10 lines, fully extracted
mk_arch "$MT/b.txt" 5                                   # 12 lines, cursor 9, a retry at 9
mk_arch "$MT/d.txt" 4 crlf                              # 11 CRLF lines, never extracted
mk_arch "$MT/e.txt" 6                                   # 13 lines, region (9,13] dead-lettered
mk_arch "$MT/f.txt" 1                                   # 8 lines, but a row says 40: recreated
mk_arch "$MT/g.txt" 2                                   # legacy ok, unchanged since its row
mk_arch "$MT/h.txt" 2                                   # legacy ok, grown since its row
mk_arch "$MT/i.txt" 2                                   # legacy error, unchanged
mk_arch "$MT/t.txt" 2; printf 'torn-no-newline' >> "$MT/t.txt"   # 9 complete lines + a torn tail
{
  printf '%s\n' '{"basename":"a.txt","ts":"2026-05-24T00:00:00Z","outcome":"ok","from":0,"lines":10}'
  printf '%s\n' '{"basename":"b.txt","ts":"2026-05-24T00:00:00Z","outcome":"ok","from":0,"lines":9}'
  printf '%s\n' '{"basename":"b.txt","ts":"2026-05-24T00:00:00Z","outcome":"retry","from":9,"lines":12,"fails":1}'
  printf '%s\n' '{"basename":"e.txt","ts":"2026-05-24T00:00:00Z","outcome":"ok","from":0,"lines":9}'
  printf '%s\n' '{"basename":"e.txt","ts":"2026-05-24T00:00:00Z","outcome":"error","from":9,"lines":13,"fails":3}'
  printf '%s\n' '{"basename":"f.txt","ts":"2026-05-24T00:00:00Z","outcome":"ok","from":0,"lines":40}'
  printf '%s\n' '{"basename":"g.txt","ts":"2026-01-03T00:00:00Z","outcome":"ok"}'
  printf '%s\n' '{"basename":"h.txt","ts":"2026-01-03T00:00:00Z","outcome":"ok"}'
  printf '%s\n' '{"basename":"i.txt","ts":"2026-01-03T00:00:00Z","outcome":"retry","fails":1}'
  printf '%s\n' '{"basename":"i.txt","ts":"2026-01-03T00:00:00Z","outcome":"error","fails":3}'
  printf '%s\n' 'GARBAGE NOT JSON'
  printf '%s\n' '{"basename":"zz-gone.txt","ts":"2026-05-24T00:00:00Z","outcome":"ok","lines":5}'
} > "$MS"
# mtimes (local-time touch; the legacy ts above is 2 days after, so any TZ keeps g/i "unchanged"):
# oldest-first order g < i < a < b < d < e < f < t < h (h is fresh = grown after its legacy row).
touch -t 202601010000 "$MT/g.txt"; touch -t 202601010001 "$MT/i.txt"
touch -t 202605240000 "$MT/a.txt"; touch -t 202605240001 "$MT/b.txt"; touch -t 202605240002 "$MT/d.txt"
touch -t 202605240003 "$MT/e.txt"; touch -t 202605240004 "$MT/f.txt"; touch -t 202605240005 "$MT/t.txt"
MAP=$(sb_drain_cursor_map "$MS" "$MT") || MAP=""
# Columns: basename cursor lines state next fails mtime flag
eq "map: one row per archive on disk (state rows for gone archives ignored)" "$(printf '%s\n' "$MAP" | grep -c . || true)" "9"
eq "map: oldest-first by mtime" "$(printf '%s\n' "$MAP" | cut -f1 | tr '\n' ' ')" "g.txt i.txt a.txt b.txt d.txt e.txt f.txt t.txt h.txt "
eq "map: a fully extracted -> cursor 10" "$(mf "$MAP" a.txt 2)" "10"
eq "map: a lines via wc -l" "$(mf "$MAP" a.txt 3)" "10"
eq "map: a state done" "$(mf "$MAP" a.txt 4)" "done"
eq "map: b retry row does not advance the cursor" "$(mf "$MAP" b.txt 2)" "9"
eq "map: b state pending (12 > 9)" "$(mf "$MAP" b.txt 4)" "pending"
eq "map: b next = cursor" "$(mf "$MAP" b.txt 5)" "9"
eq "map: b fails = trailing retries" "$(mf "$MAP" b.txt 6)" "1"
eq "map: d CRLF lines counted once each" "$(mf "$MAP" d.txt 3)" "11"
eq "map: d never extracted -> cursor 0, pending" "$(mf "$MAP" d.txt 2) $(mf "$MAP" d.txt 4)" "0 pending"
eq "map: e error row does not advance the cursor" "$(mf "$MAP" e.txt 2)" "9"
eq "map: e next skips the dead region" "$(mf "$MAP" e.txt 5)" "13"
eq "map: e state dead (tail fully dead-lettered)" "$(mf "$MAP" e.txt 4)" "dead"
eq "map: e fails reset after the error row" "$(mf "$MAP" e.txt 6)" "0"
eq "map: f recreated (8 lines < cursor 40) -> cursor 0" "$(mf "$MAP" f.txt 2)" "0"
eq "map: f recreated -> pending from 0, flagged" "$(mf "$MAP" f.txt 4) $(mf "$MAP" f.txt 5) $(mf "$MAP" f.txt 8)" "pending 0 recreated"
eq "map: t torn last line is not counted" "$(mf "$MAP" t.txt 3)" "9"
eq "map: g legacy ok unchanged -> flag baseline, cursor 0 (legacy advances nothing)" "$(mf "$MAP" g.txt 8) $(mf "$MAP" g.txt 2)" "baseline 0"
eq "map: h legacy ok grown -> flag regrow, pending from 0" "$(mf "$MAP" h.txt 8) $(mf "$MAP" h.txt 4) $(mf "$MAP" h.txt 5)" "regrow pending 0"
eq "map: i legacy error unchanged -> legacy-dead, state dead" "$(mf "$MAP" i.txt 8) $(mf "$MAP" i.txt 4)" "legacy-dead dead"
eq "map: no CR survives in the output" "$(printf '%s' "$MAP" | tr -cd '\r' | wc -c | tr -d ' ')" "0"
G_MT=$(mf "$MAP" g.txt 7); case "$G_MT" in ''|*[!0-9]*) no "map: mtime column numeric (got '$G_MT')" ;; *) ok "map: mtime column numeric" ;; esac
eq "map: absent state file -> every archive pending from 0" \
  "$(sb_drain_cursor_map "$SANDBOX/absent-state.jsonl" "$MT" | awk -F'\t' '$4 != "done" && $2 == 0' | grep -c . || true)" "9"
eq "map: absent transcripts dir -> empty, rc 0" "$(sb_drain_cursor_map "$MS" "$SANDBOX/no-such-dir"; echo "rc=$?")" "rc=0"
# X2#6: an archive `wc -l` cannot read used to vanish from the map in silence (wc's stderr and
# status were discarded): no row, so no counter, cap or drain ever saw it. The rows are compared
# with the archives on disk and the missing names logged. (wc is overridden to fail on a.txt the
# way an unreadable file does; chmod does not make a file unreadable on every platform.)
: > "$BRAIN_DIR/error-log.jsonl"
WM=$( wc() {
        if [ "$1" = "-l" ] && [ "$2" = "--" ]; then
          shift 2; local -a keep=(); local x
          for x in "$@"; do [ "$x" = "a.txt" ] || keep+=("$x"); done
          command wc -l -- "${keep[@]}"; echo "wc: a.txt: Permission denied" >&2; return 1
        fi
        command wc "$@"; }
      sb_drain_cursor_map "$MS" "$MT" )
eq "map: an unreadable archive has no row" "$(printf '%s\n' "$WM" | grep -c . || true)" "8"
grep -q 'sb_drain_cursor_map: 1 archive(s) missing from the drain accounting.*a\.txt' "$BRAIN_DIR/error-log.jsonl" \
  && ok "map: the archive missing from the accounting is logged by name" || no "map: an unreadable archive vanished in silence"

sb_drain_map_counts "$MAP"
eq "counts: total/done/pending/dead" "$SB_DM_TOTAL $SB_DM_DONE $SB_DM_PENDING $SB_DM_DEAD" "9 1 6 2"
eq "counts: extracted = cursor > 0 (a, b, e) + unmigrated legacy ok (g)" "$SB_DM_EXTRACTED" "4"
eq "counts: oldest pending mtime = g (first pending row)" "$SB_DM_OLDEST_PENDING_MTIME" "$G_MT"
eq "dead letters come from the cursor map (e region + legacy i)" "$(sb_count_drain_dead_letters "$MS" "$MT")" "2"
eq "counts: dead archives / windows / lines (e (9,13] + legacy i whole)" "$SB_DM_DEAD_ARCHIVES $SB_DM_DEAD_WINDOWS $SB_DM_DEAD_LINES" "2 2 13"
eq "map: e dead columns" "$(mf "$MAP" e.txt 9) $(mf "$MAP" e.txt 10)" "1 4"

# X2 S7 (p8): the legacy "unchanged" test had a FORWARD slack (mt <= ts + 120 s), so lines a live
# session appended up to two minutes after a 0.55 ok row were baselined as extracted, never read.
# Unchanged means mt <= ts. Fixed UTC stamps, no date arithmetic (BSD touch has no -d).
S7D="$SANDBOX/s7"; mkdir -p "$S7D"
mk_arch "$S7D/late.txt" 3; TZ=UTC touch -t 202601030001.30 "$S7D/late.txt"
mk_arch "$S7D/early.txt" 3; TZ=UTC touch -t 202601022359.00 "$S7D/early.txt"
printf '%s\n' '{"basename":"late.txt","ts":"2026-01-03T00:00:00Z","outcome":"ok"}' \
  '{"basename":"early.txt","ts":"2026-01-03T00:00:00Z","outcome":"ok"}' > "$S7D/st.jsonl"
S7M=$(sb_drain_cursor_map "$S7D/st.jsonl" "$S7D")
eq "legacy: grown 90 s after the 0.55 row -> regrow, not baseline" "$(mf "$S7M" late.txt 8)" "regrow"
eq "legacy: unchanged since the 0.55 row -> baseline" "$(mf "$S7M" early.txt 8)" "baseline"

echo "=== R2-B: sb_archive_window ==="
W="$SANDBOX/win.txt"; mk_arch "$W" 10            # header 7 lines, body lines 8..17 of 8 bytes each
eq "window: whole body"          "$(sb_archive_window "$W" 0 17 1000)" "7 80 17"
eq "window: chunk bounded by max" "$(sb_archive_window "$W" 0 17 20)"  "7 80 9"
eq "window: from inside the body" "$(sb_archive_window "$W" 12 17 1000)" "7 40 17"
eq "window: one oversized line still makes progress" "$(sb_archive_window "$W" 0 17 3)" "7 80 8"
eq "window: window entirely in the header" "$(sb_archive_window "$W" 0 3 1000)" "7 0 3"
WC="$SANDBOX/win-crlf.txt"; mk_arch "$WC" 2 crlf
eq "window: CRLF header detected, CRs not counted" "$(sb_archive_window "$WC" 0 9 1000)" "7 16 9"
WN="$SANDBOX/win-nohdr.txt"; printf 'x\nyy\n' > "$WN"
eq "window: header-less archive is all body" "$(sb_archive_window "$WN" 0 2 1000)" "0 5 2"
WT="$SANDBOX/win-torn.txt"; mk_arch "$WT" 1; printf 'torn' >> "$WT"
eq "window: torn tail beyond to is excluded" "$(sb_archive_window "$WT" 0 8 1000)" "7 8 8"

echo "=== R2-B: sb_extract_transcript delta window ==="
DX="$BRAIN_DIR/transcripts/dx_proj_2026-05-24.txt"; mk_arch "$DX" 20   # 27 lines, BODY-01 = line 8
CALLS="$SANDBOX/extractor-calls"
sb_call_extractor() {  # stub: record each input, fail when the call number is in $FAIL_CALLS
  local n; n=$(( $(cat "$CALLS.n" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$CALLS.n"
  { printf '=== CALL %s ===\n' "$n"; cat "$1"; } >> "$CALLS"
  case " ${FAIL_CALLS:-} " in *" $n "*) : > "$2"; return 1 ;; esac
  printf '{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[]}' > "$2"
  return 0
}
rm -f "$CALLS" "$CALLS.n"
SB_EXTRACT_REACHED=""
sb_extract_transcript "$DX" proj 11 15 >/dev/null 2>&1 && ok "delta: window extract returns 0" || no "delta: window extract returns 0"
grep -q 'BODY-05' "$CALLS" && grep -q 'BODY-08' "$CALLS" && ok "delta: lines (11,15] sent" || no "delta: lines (11,15] missing"
grep -q 'BODY-04' "$CALLS" && no "delta: a line at/before from leaked (no CONTEXT block allowed)" || ok "delta: nothing at/before from is sent"
grep -q 'BODY-09' "$CALLS" && no "delta: a line after to leaked" || ok "delta: nothing after to is sent"
grep -q '^=== PROJECT.md ===' "$CALLS" && ok "delta: PROJECT.md still sent" || no "delta: PROJECT.md missing"
grep -q 'project_slug:' "$CALLS" && no "delta: the meta header leaked into the window" || ok "delta: header never sent"
eq "delta: SB_EXTRACT_REACHED = to" "$SB_EXTRACT_REACHED" "15"
eq "delta: one extractor call for a small window" "$(cat "$CALLS.n")" "1"

rm -f "$CALLS" "$CALLS.n"
SB_EXTRACT_MAX_BYTES=80 sb_extract_transcript "$DX" proj >/dev/null 2>&1 && ok "chunks: 2-arg call extracts the whole archive" || no "chunks: 2-arg call failed"
eq "chunks: 20 body lines of 8 B at an 80 B cap -> 2 forward chunks" "$(cat "$CALLS.n")" "2"
FIRST=$(awk '/^=== CALL 1 ===$/{f=1;next} /^=== CALL 2 ===$/{f=0} f' "$CALLS")
printf '%s' "$FIRST" | grep -q 'BODY-01' && printf '%s' "$FIRST" | grep -q 'BODY-10' && ! printf '%s' "$FIRST" | grep -q 'BODY-11' \
  && ok "chunks: the FIRST call carries the OLDEST lines (chunked forward, no tail cap)" || no "chunks: first call is not the oldest chunk"
LAST=$(awk '/^=== CALL 2 ===$/{f=1;next} f' "$CALLS")
printf '%s' "$LAST" | grep -q 'BODY-20' && ok "chunks: the last call carries the newest line" || no "chunks: newest line missing from the last call"

rm -f "$CALLS" "$CALLS.n"
SB_EXTRACT_REACHED=""
if FAIL_CALLS=2 SB_EXTRACT_MAX_BYTES=80 sb_extract_transcript "$DX" proj 7 27 >/dev/null 2>&1; then
  no "chunks: a failing chunk must fail the call"
else
  ok "chunks: a failing chunk fails the call"
fi
eq "chunks: stop at the failing chunk (no call after it)" "$(cat "$CALLS.n")" "2"
eq "chunks: SB_EXTRACT_REACHED = end of the last good chunk" "$SB_EXTRACT_REACHED" "17"

# X2#10: the extractor input was written by an unchecked sed | tr | head inside a { } > file group,
# so a window that could not be read went out as PROJECT.md plus an empty transcript and merged
# as ok. A failed read (here: the window's sed fails) must fail the call before any extractor call.
rm -f "$CALLS" "$CALLS.n"; : > "$BRAIN_DIR/error-log.jsonl"
if ( sed() { case "$*" in "-n "*p*) return 1 ;; esac; command sed "$@"; }; sb_extract_transcript "$DX" proj 11 15 ) >/dev/null 2>&1; then
  no "input check: a window that could not be read reported success"
else
  ok "input check: a window that could not be read fails the call"
fi
eq "input check: the extractor is never called with an empty window" "$(cat "$CALLS.n" 2>/dev/null || echo 0)" "0"
grep -q 'sb_extract_transcript: cannot read archive lines' "$BRAIN_DIR/error-log.jsonl" \
  && ok "input check: the unreadable window is logged" || no "input check: the unreadable window was silent"

echo "=== R2-F#10: lossless done-set compaction (sb_compact_done_set) ==="
# The ledger gains a row per extracted window and every SessionStart parses it. Compaction keeps,
# per live basename, only the rows sb_drain_cursor_map reads. The proof: the map (all 8 columns)
# is byte-identical before and after, on archives of every shape.
CD="$SANDBOX/compact"; CT="$CD/transcripts"; CS="$CD/state.jsonl"; mkdir -p "$CT"
cmk() { local k=1; : > "$CT/$1"; while [ "$k" -le "$2" ]; do printf 'L%d\n' "$k" >> "$CT/$1"; k=$((k + 1)); done; touch -t "$3" "$CT/$1"; }
cmk grown.txt 20 202601050000        # cursor 16 < 20: pending, many ok windows
cmk dead.txt 20 202601050001         # (8,20] dead-lettered
cmk deadgrown.txt 25 202601050002    # an old dead region under the cursor, a newer one past it, a retry
cmk recreated.txt 35 202601050003    # a non-trailing retry row holds max(lines) 40 > 35
cmk weird.txt 20 202601050004        # an unknown outcome holds max(lines)
cmk legacy_ok.txt 10 202601030001    # legacy rows only; unchanged since the ok row; trailing retries
cmk legacy_err.txt 10 202601030001   # legacy rows only; the last ok|error row is an error
cmk retrying.txt 12 202601050005     # trailing retries after the cursor row
cmk stopedge.txt 40 202601050006     # the stop row before the trailing retry is a low baseline row: no other rule keeps it
cmk mixed.txt 6 202601050007         # a legacy row plus a lines row
cmk toosmall.txt 3 202601050008      # done by a too-small row
cmk norows.txt 4 202601050009        # no row at all
cmk errkeep.txt 20 202601050010      # the dead-letter row is neither the max-lines row, the stop row nor the last ok|error
cmk legacy_weird.txt 10 202601030001 # legacy rows; the last non-retry row is not ok|error
cmk mid.txt 200 202601050011         # X2#1: dead window (0,100] then ok (100,200]: done, 100 dead lines
cmk partial.txt 20 202601050012      # X2#1: dead (5,10] partly re-covered by a non-cursor ok (8,12]: 3 dead lines
r() { printf '{"basename":"%s","ts":"%s","outcome":"%s"%s}\n' "$1" "$2" "$3" "${4:-}"; }
T5="2026-01-05T00:00:00Z"; T3="2026-01-03T00:00:00Z"; T1="2026-01-01T00:00:00Z"
{
  r grown.txt "$T5" ok ',"from":0,"lines":5'; r grown.txt "$T5" ok ',"from":5,"lines":10'
  r dead.txt "$T5" ok ',"from":0,"lines":8'
  r grown.txt "$T5" retry ',"from":10,"lines":14,"fails":1'; r grown.txt "$T5" ok ',"from":10,"lines":14'
  r grown.txt "$T5" ok ',"from":14,"lines":16,"latency_s":7'
  r dead.txt "$T5" retry ',"from":8,"lines":20,"fails":1'; r dead.txt "$T5" retry ',"from":8,"lines":20,"fails":2'
  r dead.txt "$T5" error ',"from":8,"lines":20,"fails":3'
  r deadgrown.txt "$T5" ok ',"from":0,"lines":8'; r deadgrown.txt "$T5" error ',"from":8,"lines":12,"fails":3'
  r deadgrown.txt "$T5" ok ',"from":12,"lines":15'; r deadgrown.txt "$T5" error ',"from":15,"lines":18,"fails":3'
  r deadgrown.txt "$T5" retry ',"from":18,"lines":25,"fails":1'
  r recreated.txt "$T5" ok ',"from":0,"lines":10'; r recreated.txt "$T5" retry ',"from":10,"lines":40,"fails":1'
  r recreated.txt "$T5" ok ',"from":10,"lines":30'
  r weird.txt "$T5" ok ',"from":0,"lines":10'; r weird.txt "$T5" weird ',"from":10,"lines":50'; r weird.txt "$T5" ok ',"from":10,"lines":12'
  r legacy_ok.txt "$T1" error ',"fails":3'; r legacy_ok.txt "$T3" ok; r legacy_ok.txt "$T3" retry ',"fails":1'; r legacy_ok.txt "$T3" retry ',"fails":2'
  r legacy_err.txt "$T1" ok; r legacy_err.txt "$T3" error ',"fails":3'; r legacy_err.txt "$T3" retry ',"fails":1'
  r retrying.txt "$T5" ok ',"from":0,"lines":4'; r retrying.txt "$T5" retry ',"from":4,"lines":12,"fails":1'
  r retrying.txt "$T5" retry ',"from":4,"lines":12,"fails":2'
  r stopedge.txt "$T5" ok ',"from":0,"lines":10'; r stopedge.txt "$T5" retry ',"from":10,"lines":30,"fails":1'
  r stopedge.txt "$T5" baseline ',"from":0,"lines":5'; r stopedge.txt "$T5" retry ',"from":10,"lines":11,"fails":1'
  r mixed.txt "$T1" ok; r mixed.txt "$T5" ok ',"from":0,"lines":6'
  r toosmall.txt "$T5" ok ',"reason":"too-small","from":0,"lines":3'
  r errkeep.txt "$T5" ok ',"from":0,"lines":8'; r errkeep.txt "$T5" error ',"from":8,"lines":20,"fails":3'
  r errkeep.txt "$T5" retry ',"from":8,"lines":20,"fails":1'; r errkeep.txt "$T5" ok ',"from":0,"lines":5'
  r legacy_weird.txt "$T3" ok; r legacy_weird.txt "$T3" weird
  r mid.txt "$T5" error ',"from":0,"lines":100,"fails":3'; r mid.txt "$T5" ok ',"from":100,"lines":200'
  r partial.txt "$T5" ok ',"from":0,"lines":5'; r partial.txt "$T5" error ',"from":5,"lines":10,"fails":3'
  r partial.txt "$T5" ok ',"from":8,"lines":12'; r partial.txt "$T5" ok ',"from":12,"lines":20'
  r gone.txt "$T5" ok ',"from":0,"lines":9'                            # no archive: dropped
  printf '%s\n' 'not json' '{"basename":5,"outcome":"ok","lines":3}' '' '{"basename":"grown.txt","ts":"'"$T5"'","outcome":"ok","from":16,"li'
} > "$CS"
CM0=$(sb_drain_cursor_map "$CS" "$CT"); CN0=$(grep -c . "$CS")
[ "$(printf '%s\n' "$CM0" | grep -c .)" -eq 16 ] || no "compact: fixture map should have 16 rows (got: $CM0)"
sb_compact_done_set "$CS" "$CT" && ok "compact: returns 0" || no "compact: returned non-zero"
CM1=$(sb_drain_cursor_map "$CS" "$CT"); CN1=$(grep -c . "$CS")
# X2#1: a dead-lettered window stays counted (columns 9 dead_windows, 10 dead_lines) whatever the
# state, before AND after compaction: a later ok window past it used to make it vanish.
for cm in CM0 CM1; do
  eq "dead ($cm): a dead window under the cursor still counts (state windows lines)" \
    "$(mf "${!cm}" mid.txt 4) $(mf "${!cm}" mid.txt 9) $(mf "${!cm}" mid.txt 10)" "done 1 100"
  eq "dead ($cm): an ok window overlapping a dead one takes its lines back" "$(mf "${!cm}" partial.txt 9) $(mf "${!cm}" partial.txt 10)" "1 3"
  eq "dead ($cm): both dead regions of deadgrown count (one under the cursor)" "$(mf "${!cm}" deadgrown.txt 9) $(mf "${!cm}" deadgrown.txt 10)" "2 7"
  eq "dead ($cm): a legacy dead archive counts whole" "$(mf "${!cm}" legacy_err.txt 9) $(mf "${!cm}" legacy_err.txt 10)" \
    "$( [ "$(mf "${!cm}" legacy_err.txt 8)" = legacy-dead ] && echo '1 10' || echo '0 0')"
  eq "dead ($cm): a recreated archive has none" "$(mf "${!cm}" recreated.txt 9) $(mf "${!cm}" recreated.txt 10)" "0 0"
done
sb_drain_map_counts "$CM1"
eq "counts: dead archives / windows / lines after compaction" "$SB_DM_DEAD_ARCHIVES $SB_DM_DEAD_WINDOWS $SB_DM_DEAD_LINES" \
  "$( [ "$(mf "$CM1" legacy_err.txt 8)" = legacy-dead ] && echo '6 7 144' || echo '5 6 134')"   # dead+deadgrown+errkeep+mid+partial (+legacy_err when its flag is legacy-dead in this TZ)
[ "$CM1" = "$CM0" ] && ok "compact: the cursor map is identical before and after (all 10 columns, 16 archives)" \
  || no "compact: the map changed:"$'\n'"$(diff <(printf '%s\n' "$CM0") <(printf '%s\n' "$CM1"))"
[ "$CN1" -lt "$CN0" ] && ok "compact: the ledger shrank ($CN0 -> $CN1 rows)" || no "compact: nothing was compacted ($CN0 -> $CN1)"
eq "compact: grown keeps only its cursor row" "$(grep -c '"basename":"grown.txt"' "$CS")" "1"
grep -q '"basename":"grown.txt".*"lines":16,"latency_s":7' "$CS" && ok "compact: rows are kept verbatim" || no "compact: the kept row was rewritten"
grep -q 'gone.txt' "$CS" && no "compact: a row of a vanished archive survived" || ok "compact: rows of vanished archives dropped"
grep -qv '^{"basename":"' "$CS" && no "compact: an unparseable row survived" || ok "compact: unparseable rows dropped"
cp "$CS" "$CD/once"; sb_compact_done_set "$CS" "$CT" || no "compact: the second pass returned non-zero"
cmp -s "$CS" "$CD/once" && ok "compact: idempotent" || no "compact: a second pass changed the ledger"
# a failure keeps the ledger as it is and is loud
cp "$CS" "$CD/before-fail"; : > "$BRAIN_DIR/error-log.jsonl"
( jq() { case " $* " in *" --rawfile "*) return 5 ;; esac; command jq "$@"; }; sb_compact_done_set "$CS" "$CT" ) && no "compact: a failed jq returned 0" || ok "compact: a failed jq returns non-zero"
cmp -s "$CS" "$CD/before-fail" && ok "compact: a failed pass leaves the ledger intact" || no "compact: a failed pass changed the ledger"
grep -q 'sb_compact_done_set' "$BRAIN_DIR/error-log.jsonl" && ok "compact: a failed pass is logged" || no "compact: a failed pass was silent"
[ -z "$(find "$CD" -name 'state.jsonl.*')" ] && ok "compact: no scratch file left" || no "compact: a scratch file was left behind"

echo "=== X2 S1/S2/S4: eviction under the archive lock, tombstones, the subagent sub-cap ==="
# S1: the prune classified from a map snapshot and removed with no archive lock, so an append that
# landed in between was deleted with the file (the appender's raw cursor had already advanced).
# S2: a basename re-created after its eviction inherited the stale cursor once it grew past it.
# S4: the subagent sub-cap deleted the oldest sub-*.txt whether or not it was ever extracted.
PB="$SANDBOX/prune-brain"; PT="$PB/transcripts"; PS="$PB/.extraction-state.jsonl"
pmk() {  # $1 = name, $2 = line count, $3 = touch stamp
  local k=1; : > "$PT/$1"; while [ "$k" -le "$2" ]; do printf 'L%d\n' "$k" >> "$PT/$1"; k=$((k + 1)); done
  touch -t "$3" "$PT/$1"
}
pok() { printf '{"basename":"%s","ts":"%s","outcome":"ok","from":0,"lines":%s}\n' "$1" "${3:-2026-10-01T00:00:00Z}" "$2" >> "$PS"; }
preset() { rm -rf "$PB"; mkdir -p "$PT"; : > "$PS"; : > "$PB/error-log.jsonl"; : > "$PB/audit-log.jsonl"; }
pmap() { BRAIN_DIR="$PB" sb_drain_cursor_map "$PS" "$PT" | awk -F'\t' -v b="$1" -v k="$2" '$1 == b { print $k; exit }'; }
pfour() {  # A (done, oldest) + three newer pending archives: one over a cap of 3
  pmk sA.txt 10 202610010000; pok sA.txt 10
  pmk o1.txt 2 202610020000; pmk o2.txt 2 202610020001; pmk o3.txt 2 202610020002
}
# S2: eviction leaves a tombstone; the re-created archive restarts at 0 even past the old cursor.
# The evicted incarnation also holds a dead window (an error row: compaction keeps every one), so
# only the tombstone filter can drop its rows.
preset; pmk sA.txt 12 202610010000; pok sA.txt 10
printf '{"basename":"sA.txt","ts":"2026-10-01T00:00:00Z","outcome":"error","from":10,"lines":12,"fails":3}\n' >> "$PS"
pmk o1.txt 2 202610020000; pmk o2.txt 2 202610020001; pmk o3.txt 2 202610020002
( BRAIN_DIR="$PB" SB_TRANSCRIPT_CAP=3 sb_prune_transcripts )
[ ! -e "$PT/sA.txt" ] && [ -f "$PT/.sA.txt.evicted" ] && ok "tombstone: the evicted archive leaves .<name>.evicted" \
  || no "tombstone: missing after eviction ($(ls -a "$PT" | tr '\n' ' '))"
pmk sA.txt 15 202610030000                            # same basename, re-created, grew past cursor 10
eq "tombstone: a re-created archive restarts at 0 (cursor state next dead)" \
  "$(pmap sA.txt 2) $(pmap sA.txt 4) $(pmap sA.txt 5) $(pmap sA.txt 9)" "0 pending 0 0"
pok sA.txt 5 2099-01-01T00:00:00Z                     # the new incarnation's first window (after the tombstone)
eq "tombstone: rows written after the eviction count" "$(pmap sA.txt 2) $(pmap sA.txt 4)" "5 pending"
TM0=$(BRAIN_DIR="$PB" sb_drain_cursor_map "$PS" "$PT")
( BRAIN_DIR="$PB" sb_compact_done_set "$PS" "$PT" ) || no "tombstone: compaction failed"
grep -q '"ts":"2026-10-01T00:00:00Z"' "$PS" && no "tombstone: compaction kept the stale row" || ok "tombstone: compaction drops the pre-eviction rows"
[ ! -e "$PT/.sA.txt.evicted" ] && ok "tombstone: consumed by the compaction" || no "tombstone: still there after the compaction"
eq "tombstone: the map is identical after the consumption" "$(BRAIN_DIR="$PB" sb_drain_cursor_map "$PS" "$PT")" "$TM0"
# a compaction that fails keeps the tombstone (and the ledger)
preset; pfour; ( BRAIN_DIR="$PB" SB_TRANSCRIPT_CAP=3 sb_prune_transcripts ); pmk sA.txt 15 202610030000
( BRAIN_DIR="$PB"; jq() { case " $* " in *" --rawfile "*) return 5 ;; esac; command jq "$@"; }; sb_compact_done_set "$PS" "$PT" ) >/dev/null 2>&1 || :
[ -f "$PT/.sA.txt.evicted" ] && ok "tombstone: kept when the compaction fails" || no "tombstone: removed by a failed compaction"
# S1: an append that lands between the classification and the rm keeps the archive
preset; pfour
eval "$(declare -f sb_drain_cursor_map | sed '1s/sb_drain_cursor_map/_s1_real_map/')"
( BRAIN_DIR="$PB" SB_TRANSCRIPT_CAP=3
  sb_drain_cursor_map() { local r=0; _s1_real_map "$@" || r=$?; printf 'L11\n' >> "$PT/sA.txt"; return "$r"; }
  sb_prune_transcripts )
eq "lock: an archive that grew after the classification is kept (lines)" "$(wc -l < "$PT/sA.txt" 2>/dev/null | tr -d ' ')" "11"
[ ! -e "$PT/.sA.txt.evicted" ] && [ ! -e "$PT/.sA.txt.lock" ] && ok "lock: no tombstone and no lock left for the kept archive" \
  || no "lock: tombstone/lock left behind ($(ls -a "$PT" | tr '\n' ' '))"
# ...and an archive whose lock a writer holds is skipped this round (the writer's lock untouched)
preset; pfour; printf '99999\n' > "$PT/.sA.txt.lock"
( BRAIN_DIR="$PB" SB_TRANSCRIPT_CAP=3 sb_prune_transcripts )
[ -f "$PT/sA.txt" ] && [ -f "$PT/.sA.txt.lock" ] && ok "lock: a locked archive is skipped and its lock left alone" \
  || no "lock: a locked archive was evicted or its lock removed"
# ...a lock that cannot be created at all (no lock file) is an error, not a skip-forever in silence
( BRAIN_DIR="$PB" SB_TRANSCRIPT_CAP=3; _sb_archive_lock_try() { return 1; }; rm -f "$PT/.sA.txt.lock"; sb_prune_transcripts )
[ -f "$PT/sA.txt" ] && grep -q 'cannot create the archive lock' "$PB/error-log.jsonl" \
  && ok "lock: an uncreatable lock keeps the archive and is logged as an error" || no "lock: an uncreatable lock was silent or evicted anyway"
rm -f "$PT/.sA.txt.lock"
( BRAIN_DIR="$PB" SB_TRANSCRIPT_CAP=3 sb_prune_transcripts )
[ ! -e "$PT/sA.txt" ] && [ ! -e "$PT/.sA.txt.lock" ] && ok "lock: evicted next round, and the prune's own lock released" \
  || no "lock: next-round eviction wrong ($(ls -a "$PT" | tr '\n' ' '))"
# item 9: evicting an archive that holds dead-lettered windows leaves one summary row
preset; pmk dX.txt 10 202610010000
printf '{"basename":"dX.txt","ts":"2026-10-01T00:00:00Z","outcome":"error","from":0,"lines":10,"fails":3}\n' > "$PS"
pmk o1.txt 2 202610020000; pmk o2.txt 2 202610020001; pmk o3.txt 2 202610020002
( BRAIN_DIR="$PB" SB_TRANSCRIPT_CAP=3 sb_prune_transcripts )
grep -q 'gate=transcript-cap evicted 1 archive(s) holding dead-lettered windows (1 window(s), 10 lines' "$PB/audit-log.jsonl" \
  && ok "cap: a dead-lettered eviction is logged once" || no "cap: dead-lettered eviction not logged ($(cat "$PB/audit-log.jsonl" "$PB/error-log.jsonl"))"
# S4: the sub-cap protects un-extracted sub-*.txt: done ones go past SB_SUBAGENT_ARCHIVE_CAP, pending
# ones only past 3x that, loudly
preset
for s in a b c; do pmk "sub-$s.txt" 3 "20261001000$( case $s in a) echo 1;; b) echo 2;; c) echo 3;; esac)"; done
( BRAIN_DIR="$PB" SB_SUBAGENT_ARCHIVE_CAP=2 sb_prune_transcripts )
eq "sub-cap: un-extracted sub archives over the soft sub-cap are kept" "$(ls "$PT" | grep -c '^sub-')" "3"
pok sub-a.txt 3; pok sub-b.txt 3                      # a and b extracted: they may go
( BRAIN_DIR="$PB" SB_SUBAGENT_ARCHIVE_CAP=2 sb_prune_transcripts )
eq "sub-cap: extracted sub archives are evicted down to the sub-cap, oldest first" "$(ls "$PT" | grep '^sub-' | tr '\n' ' ')" "sub-b.txt sub-c.txt "
preset
for s in 1 2 3 4 5 6 7; do pmk "sub-p$s.txt" 3 "20261001000$s"; done
( BRAIN_DIR="$PB" SB_SUBAGENT_ARCHIVE_CAP=2 sb_prune_transcripts )
[ ! -e "$PT/sub-p1.txt" ] && [ "$(ls "$PT" | grep -c '^sub-')" = "6" ] && ok "sub-cap: un-extracted ones go only past 3x the sub-cap, oldest first" \
  || no "sub-cap: hard sub ceiling wrong ($(ls "$PT" | tr '\n' ' '))"
grep -q 'UN-EXTRACTED.*sub-p1.txt' "$PB/error-log.jsonl" && ok "sub-cap: an un-mined sub eviction is loud" || no "sub-cap: un-mined sub eviction was silent"
# p5a end to end: sb_archive_subagent_result no longer runs its own blind sub-cap
preset
( BRAIN_DIR="$PB" SB_SUBAGENT_ARCHIVE_CAP=2
  for a in agA agB agC; do sb_archive_subagent_result "$a" general proj parentS 3 "result of $a" </dev/null; done )
eq "sub-cap: three never-extracted subagent results all survive a sub-cap of 2" "$(ls "$PT" | grep -c '^sub-ag')" "3"

echo "=== R2-B: source-scan lock — no basename-set 'done' readers ==="
# The pre-R2 readers each derived "done" as {basename : some ok|error row}. Four copies drifted
# (extract-drain, session-load, sb.ts, sb-health-snapshot). sb_drain_cursor_map is now the ONE
# accounting primitive; this lock fails on any new copy of the old derivation.
LOCK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# No allowlist: sb_prune_transcripts, the last old-set reader, classifies through
# sb_drain_cursor_map since R2-F (eviction protects state == pending).
LOCK_HITS=""
for lf in "$LOCK_ROOT"/scripts/*.sh "$LOCK_ROOT"/.claude/skills/*/scripts/*.sh $(find "$LOCK_ROOT/mcp/src" -name '*.ts' ! -name '*.test.ts' 2>/dev/null); do
  [ -f "$lf" ] || continue
  rel="${lf#"$LOCK_ROOT"/}"
  hits=$(grep -nE \
    -e 'outcome[[:space:]]*==[[:space:]]*"(ok|error)"[[:space:]]*or[[:space:]]*\.outcome[[:space:]]*==[[:space:]]*"(ok|error)"' \
    -e "outcome[[:space:]]*===?[[:space:]]*['\"](ok|error)['\"][[:space:]]*\|\|[[:space:]]*[A-Za-z_.]*outcome[[:space:]]*===?[[:space:]]*['\"](ok|error)['\"]" \
    -e 'grep[^|]*"outcome":"ok"' \
    -e 'sb_extraction_done' \
    "$lf" 2>/dev/null || true)
  [ -n "$hits" ] || continue
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    hl="${h#*:}"; hl="${hl#"${hl%%[![:space:]]*}"}"
    case "$hl" in '#'*|'//'*|'*'*) continue ;; esac   # a comment naming the old reader is not one
    LOCK_HITS="$LOCK_HITS$rel:$h"$'\n'
  done <<< "$hits"
done
[ -z "$LOCK_HITS" ] && ok "lock: no reader derives done from a basename set of ok|error rows" \
  || no "lock: basename-set readers remain (use sb_drain_cursor_map):"$'\n'"$LOCK_HITS"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
