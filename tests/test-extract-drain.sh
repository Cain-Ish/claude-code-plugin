#!/bin/bash
# Tests for extract-drain.sh
# run-all-timeout: 600   (~66 full drainer ticks by design since the R2-B delta-drain and R2-F scrub-migration cases; measured 233-302s on the MSYS dev box — see run-all.sh)
# shellcheck disable=SC2015  # `cond && ok || no`: ok/no always return 0, so || is never wrongly taken
# pins: SB_DRAIN_QUIET_S — =0 treats the tiny fresh fixtures as settled; D7 + the too-small case set 3600 to test the gate itself
# pins: SB_EXTRACT_MAX_BYTES — D8 shrinks the chunk cap so a 37-line fixture spans several forward chunks
# pins: SB_DRAIN_STALE_MAX — D3 raises it so the deferred-tick migration case cannot take the age escape
# pins: SB_DRAIN_BATCH — D8/D8b/D9 size the per-tick extractor-call budget that is under test
# pins: SB_DRAIN_FLOOR — D2 turns the deterministic floor off so MAX_FAILS yields the error row under test
# pins: SB_DRAIN_MAX_FAILS — D2 fixes the dead-letter threshold the retry/error rows are asserted against
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
DRAIN="$SCRIPT_DIR/extract-drain.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export BRAIN_DIR="$SANDBOX/brain"
mkdir -p "$BRAIN_DIR/transcripts"
STATE="$BRAIN_DIR/.extraction-state.jsonl"

# These tests run the drainer for its processing behavior. When the suite runs
# inside a Claude Code session, CLAUDECODE=1 leaks in and the drainer (correctly)
# refuses — so unset it here for determinism. Test 1 re-sets it explicitly.
unset CLAUDECODE 2>/dev/null || true
# The suite also runs while an interactive `claude` is alive (the session running
# it), which the new defer-guard would (correctly) skip on. Force the guard to
# "inactive" for the processing tests; the defer test overrides to "active".
export SB_INTERACTIVE_OVERRIDE=inactive
# R1.2: the too-small fast-path would skip these deliberately tiny fixtures —
# disable it for the legacy cases; the fast-path test re-enables it per-call.
export SB_DRAIN_MIN_BYTES=0
# R2-B: an archive is eligible once >= SB_DRAIN_DELTA_MIN_BYTES (4 KB) is new OR it has been quiet
# SB_DRAIN_QUIET_S (1 h). The fixtures here are tiny and fresh, so every archive is treated as
# settled; the eligibility cases (D7, the too-small fast-path) set SB_DRAIN_QUIET_S per call.
export SB_DRAIN_QUIET_S=0
# brain-os OFF by default. Every drainer tick also runs brain-os-run.sh (maintain-deterministic:
# archive prune + project backfill + codemap + wiki-history) — ~13s/tick on the dev box even
# after the 2026-08-23 spawn fixes (67s before). Only the 4 codemap cases below assert on it;
# the other 27 ticks paid that cost for nothing, which is the single reason this test could
# never fit the 120s suite budget on Windows (1290s -> 259s -> 112s). The codemap cases
# re-enable it per call with SB_BRAIN_OS=on.
export SB_BRAIN_OS=off

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS: $1"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
eq() { [ "$2" = "$3" ] && ok "$1" || no "$1 — got '$2' want '$3'"; }

# A stub that "extracts" a transcript: succeeds unless the slug is 'poison'.
# The drainer calls: "$SB_EXTRACT_STUB" <txt> <slug>
STUB="$SANDBOX/stub.sh"
cat > "$STUB" <<'EOF'
#!/bin/bash
slug="$2"
[ "$slug" = "poison" ] && exit 1
exit 0
EOF
chmod +x "$STUB"
export SB_EXTRACT_STUB="$STUB"

mk_tx() {  # $1 = name, $2 = slug
  local f="$BRAIN_DIR/transcripts/$1"
  cat > "$f" <<EOF
--- session-meta ---
session_id: ${1%%_*}
project_slug: $2
date: 2026-05-24
tool_count: 2
line_count: 4
---

USER: x
ASSISTANT: y
EOF
}
done_count() { [ -f "$STATE" ] && grep -c '"outcome":"ok"' "$STATE" || echo 0; }
reset() { rm -rf "$BRAIN_DIR/transcripts" "$STATE" "$BRAIN_DIR/.extract-drain.lock"; mkdir -p "$BRAIN_DIR/transcripts"; }

echo "=== extract-drain.sh tests ==="

# Test 1: refuses to run inside a session
reset; mk_tx "s1_proj_2026-05-24.txt" proj
CLAUDECODE=1 bash "$DRAIN" >/dev/null 2>&1 || true
eq "in-session refusal leaves state empty" "$(done_count)" "0"

# Test 1b: an interactive claude session active → defer cleanly (no work, no state)
reset; mk_tx "s1_proj_2026-05-24.txt" proj
SB_INTERACTIVE_OVERRIDE=active SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
eq "interactive session → no extraction" "$(done_count)" "0"
[ ! -f "$STATE" ] && ok "interactive defer writes no state at all" || no "interactive defer wrote state"

# Test 2: processes up to BATCH oldest-first
reset
for i in 1 2 3 4 5 6 7; do mk_tx "s${i}_proj_2026-05-24.txt" proj; sleep 0.05; done
SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
eq "batch of 5 processed" "$(done_count)" "5"

# Test 3: a done transcript is not reprocessed; remaining 2 drain next run
SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
eq "remaining 2 drained, total 7" "$(done_count)" "7"

# Test 4: poison transcript → retry then terminal error after MAX_FAILS
reset; mk_tx "p1_poison_2026-05-24.txt" poison
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # retry 1
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # retry 2
RETRIES=$(grep -c '"outcome":"retry"' "$STATE" || true)
eq "poison: 2 retries recorded" "$RETRIES" "2"
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # 3rd → terminal error
ERRORS=$(grep -c '"outcome":"error"' "$STATE" || true)
eq "poison: 1 terminal error" "$ERRORS" "1"
# R2-F#10: once dead-lettered, the retry rows before it are compacted away (the cursor map reads
# only the error row); the error row itself records the attempts
grep -q '"outcome":"error".*"fails":3' "$STATE" && ok "poison: the error row records the 3 attempts" \
  || no "poison: the error row lost its fails count (got: $(cat "$STATE"))"
cp "$STATE" "$SANDBOX/poison.before"
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # must NOT touch it again
cmp -s "$STATE" "$SANDBOX/poison.before" && ok "poison: not reprocessed after terminal" \
  || no "poison: the dead-lettered transcript was touched again (got: $(cat "$STATE"))"

# Test 4b: a run where everything fails → health status must be "fail" (not clobbered to ok)
reset; mk_tx "f1_poison_2026-05-24.txt" poison
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true
HSTATUS=$(jq -r '.status // ""' "$BRAIN_DIR/.extractor-health.json" 2>/dev/null)
eq "all-fail run reports health=fail" "$HSTATUS" "fail"

# Test 5: lock held → no-op (flock-based; skipped when flock absent — mkdir-lock
# variant is tested in tests 5b/5c below and runs on all platforms)
if command -v flock >/dev/null 2>&1; then
  reset; mk_tx "s1_proj_2026-05-24.txt" proj
  exec 8>"$BRAIN_DIR/.extract-drain.lock"; flock -n 8
  SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
  flock -u 8; exec 8>&-
  eq "lock contention is a no-op" "$(done_count)" "0"
else
  ok "lock contention is a no-op (flock absent — mkdir-lock path tested in 5b/5c)"
fi

# Test 2c (U2): summary health reports the REAL backend, not hardcoded "cli-oauth"
# (the stub writes no per-call backend → summary should read the health file and
# default to "drainer", never overwrite a real backend with a fixed label).
reset; mk_tx "b1_proj_2026-05-24.txt" proj
SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
HBACK=$(jq -r '.backend // ""' "$BRAIN_DIR/.extractor-health.json" 2>/dev/null)
[ "$HBACK" != "cli-oauth" ] && ok "summary backend not hardcoded cli-oauth (got '$HBACK')" || no "summary hardcoded backend=cli-oauth"

# Test 2d (U2): the summary PRESERVES the real backend the per-transcript extractor
# wrote (e.g. local), rather than overwriting it. Pre-seed a real backend; the stub
# writes no health, so the summary must read+keep it.
reset; mk_tx "c1_proj_2026-05-24.txt" proj
printf '{"checked_at":"x","backend":"local","status":"ok","reason":""}\n' > "$BRAIN_DIR/.extractor-health.json"
SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
eq "summary preserves real backend=local" "$(jq -r '.backend // ""' "$BRAIN_DIR/.extractor-health.json" 2>/dev/null)" "local"

# SP-3 (cross-OS): no Linux-only /proc read in the drainer (breaks on macOS).
grep -q '/proc/' "$DRAIN" && no "drainer still reads /proc (Linux-only)" || ok "no /proc read (portable defer-guard)"

# Test 5b (SP-3): portable mkdir-lock — a held (fresh) lock is a no-op.
reset; mk_tx "m1_proj_2026-05-24.txt" proj
mkdir -p "$BRAIN_DIR/.extract-drain.lock.d"          # simulate a live run holding the lock
SB_DRAIN_FORCE_MKDIR_LOCK=1 SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
eq "fresh mkdir-lock held → no-op" "$(done_count)" "0"
rmdir "$BRAIN_DIR/.extract-drain.lock.d" 2>/dev/null

# Test 5c (SP-3): a STALE mkdir-lock is stolen → the drain proceeds.
reset; mk_tx "m2_proj_2026-05-24.txt" proj
mkdir -p "$BRAIN_DIR/.extract-drain.lock.d"
touch -t 202001010000 "$BRAIN_DIR/.extract-drain.lock.d" 2>/dev/null
SB_DRAIN_FORCE_MKDIR_LOCK=1 SB_DRAIN_LOCK_STALE=60 SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
eq "stale mkdir-lock stolen → drained" "$(done_count)" "1"

# Test fast-path (R1.2, HOOK-5): a sub-MIN_BYTES archive body (e.g. a 378-byte
# workflow-subagent stub) is marked done WITHOUT an LLM spawn, exactly once.
echo "Test: too-small fast-path marks done without an LLM spawn"
reset
CALLED="$SANDBOX/called"; rm -f "$CALLED"
FPSTUB="$SANDBOX/fpstub.sh"
cat > "$FPSTUB" <<EOF2
#!/bin/bash
touch "$CALLED"
exit 0
EOF2
chmod +x "$FPSTUB"
mk_tx "tiny1_x.txt" someproj     # mk_tx bodies are well under 1KB
touch -t 202601010000 "$BRAIN_DIR/transcripts/tiny1_x.txt"   # settled: quiet for months
SB_EXTRACT_STUB="$FPSTUB" SB_DRAIN_QUIET_S=3600 SB_DRAIN_MIN_BYTES=1024 bash "$DRAIN" >/dev/null 2>&1 || true
grep -q '"basename":"tiny1_x.txt"' "$STATE" 2>/dev/null && grep -q '"reason":"too-small"' "$STATE" 2>/dev/null \
  && ok "too-small archive marked ok/too-small in state" || no "too-small not recorded in state"
[ ! -f "$CALLED" ] && ok "extractor NOT spawned for too-small archive" || no "extractor was spawned for a too-small archive"
# Idempotent: second run must skip it via sb_extraction_done.
SB_EXTRACT_STUB="$FPSTUB" SB_DRAIN_QUIET_S=3600 SB_DRAIN_MIN_BYTES=1024 bash "$DRAIN" >/dev/null 2>&1 || true
eq "too-small recorded exactly once" "$(grep -c '"basename":"tiny1_x.txt"' "$STATE" 2>/dev/null)" "1"
# Header guard (deep-review): a file WITHOUT the ^---$ terminator must NOT be
# fast-path-classified too-small (sed reported 0 bytes for real content). R2-B measures a
# header-less archive as all body, so a real >1 KB body is never too-small.
{ printf 'no header here\n'; head -c 1500 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$BRAIN_DIR/transcripts/nohdr_x.txt"
touch -t 202601010000 "$BRAIN_DIR/transcripts/nohdr_x.txt"
SB_EXTRACT_STUB="$FPSTUB" SB_DRAIN_QUIET_S=3600 SB_DRAIN_MIN_BYTES=1024 bash "$DRAIN" >/dev/null 2>&1 || true
grep -q '"basename":"nohdr_x.txt".*"reason":"too-small"' "$STATE" 2>/dev/null \
  && no "header-less archive misclassified as too-small" || ok "header-less archive not fast-path-classified"

# Test (CRITICAL): the drainer WRITES A REAL WIKI PAGE end-to-end. Unlike the
# write-nothing STUB above, this stub emits a canned extractor delta and pipes it
# through the REAL merge-project-update.sh — so a green drain run is proven by an
# actual page on disk with its content body, not just outcome:ok in the state log.
echo "Test: drain writes a real wiki page through the real merge"
reset
DRAIN_KDIR="$SANDBOX/drain-knowledge"; rm -rf "$DRAIN_KDIR"; mkdir -p "$DRAIN_KDIR/wiki"
DRAIN_PROJ="$BRAIN_DIR/projects/proj/PROJECT.md"
mkdir -p "$(dirname "$DRAIN_PROJ")"
cat > "$DRAIN_PROJ" <<'PMEOF'
# PROJECT: proj

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: 2026-05-01T00:00:00Z -->
PMEOF
# A stub standing in for sb_extract_transcript: it emits the extractor's JSON
# delta and runs it through the SAME merge the real path uses. Receives <txt> <slug>.
MERGESTUB="$SANDBOX/merge-stub.sh"
cat > "$MERGESTUB" <<EOF3
#!/bin/bash
printf '%s' '{"wiki_updates":[{"category":"learnings","slug":"drained-page","action":"create","title":"T","description":"d","content":"REAL DRAINED INSIGHT BODY"}]}' \\
  | bash "$SCRIPT_DIR/merge-project-update.sh" --project-md "$DRAIN_PROJ" --knowledge-dir "$DRAIN_KDIR" >/dev/null 2>&1
EOF3
chmod +x "$MERGESTUB"
mk_tx "d1_proj_2026-05-24.txt" proj
SB_EXTRACT_STUB="$MERGESTUB" SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
DRAINED_PAGE="$DRAIN_KDIR/wiki/learnings/drained-page.md"
[ -f "$DRAINED_PAGE" ] && ok "drain created the wiki page on disk" || no "drain did not create $DRAINED_PAGE"
grep -qF 'REAL DRAINED INSIGHT BODY' "$DRAINED_PAGE" 2>/dev/null \
  && ok "drained page contains the real insight body" || no "drained page missing the insight body"
eq "drain recorded the transcript as ok" "$(done_count)" "1"

# --- P1 last-resort deterministic floor: when the LLM backend fails MAX_FAILS times, the drainer
# captures a real files-changed delta from the archived transcript (no LLM) instead of quarantining
# empty. The floor fires ONLY at the quarantine boundary (LLM retry preserved until then). The poison
# stub fails the LLM path; the floor (real, not stubbed) parses the archived [Edit]/[Write] lines. ---
echo "Test: last-resort deterministic floor at the quarantine boundary"
reset
FLOOR_KDIR="$SANDBOX/floor-knowledge"; rm -rf "$FLOOR_KDIR"; mkdir -p "$FLOOR_KDIR/wiki"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$FLOOR_KDIR"
FLOOR_PROJ="$BRAIN_DIR/projects/poison/PROJECT.md"; mkdir -p "$(dirname "$FLOOR_PROJ")"
mk_proj() { cat > "$1" <<'PMEOF'
# PROJECT: poison

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: 2026-05-01T00:00:00Z -->
PMEOF
}
mk_proj "$FLOOR_PROJ"
cat > "$BRAIN_DIR/transcripts/fl1_poison_2026-05-24.txt" <<'TXEOF'
--- session-meta ---
session_id: fl1
project_slug: poison
date: 2026-05-24
tool_count: 3
line_count: 9
---

USER: do the thing
ASSISTANT:
  [Edit] /work/src/a.ts
  [Read] /work/src/ignore-me.ts
  [Write] /work/src/b.ts
TXEOF
SB_DRAIN_MAX_FAILS=1 bash "$DRAIN" >/dev/null 2>&1 || true   # 1st failure == quarantine boundary → floor
grep -q '"reason":"deterministic-floor"' "$STATE" 2>/dev/null && ok "floor: marks ok/deterministic-floor at MAX_FAILS" || no "floor: no deterministic-floor outcome recorded"
eq "floor: a floored transcript is not an error" "$(grep -c '"outcome":"error"' "$STATE" 2>/dev/null)" "0"
grep -q '\[auto-captured\]' "$FLOOR_PROJ" 2>/dev/null && ok "floor: wrote an [auto-captured] decision to PROJECT.md" || no "floor: PROJECT.md got no auto-captured decision"
{ grep -q '/work/src/a.ts' "$FLOOR_PROJ" && grep -q '/work/src/b.ts' "$FLOOR_PROJ"; } 2>/dev/null && ok "floor: decision cites the Edit + Write files" || no "floor: decision missing the changed files"
grep -q 'ignore-me.ts' "$FLOOR_PROJ" 2>/dev/null && no "floor: leaked a Read-only file into the decision" || ok "floor: excluded the Read-only file"

# WINDOWS-PATH boundary (the real cross-platform case the POSIX fixtures above miss): on Windows the
# archived tool lines carry backslash paths ("C:\Work\...\tests\test.ts"). Two ways this corrupts:
#   (1) awk -v new=... in merge-project-update.sh escape-processes the value → \t becomes a TAB, \W
#       drops the backslash → garbage path. (2) un-normalized backslashes are unclickable.
# Assert the floored decision carries the path CLEAN: forward-slashed, intact, no TAB.
echo "Test: floor handles Windows backslash paths without mangling"
reset
mk_proj "$FLOOR_PROJ"
printf '%s\r\n' '--- session-meta ---' 'project_slug: poison' 'date: 2026-05-24' '---' '' 'USER: w' 'ASSISTANT:' '  [Edit] C:\Work\proj\tests\test-thing.ts' '  [Write] C:\Work\proj\src\app.ts' > "$BRAIN_DIR/transcripts/flw_poison_2026-05-24.txt"
SB_DRAIN_MAX_FAILS=1 bash "$DRAIN" >/dev/null 2>&1 || true
WDEC=$(awk '/^## Recent decisions/{f=1;next}/^## /{f=0}f' "$FLOOR_PROJ")
printf '%s' "$WDEC" | grep -qF 'C:/Work/proj/tests/test-thing.ts' && ok "win-path: Edit path normalized to forward slashes, intact" || no "win-path: Edit path mangled/missing (got: $(printf '%s' "$WDEC" | head -c 200))"
printf '%s' "$WDEC" | grep -qF 'C:/Work/proj/src/app.ts' && ok "win-path: Write path normalized, intact" || no "win-path: Write path mangled/missing"
printf '%s' "$WDEC" | grep -q $'\t' && no "win-path: \\t in a path expanded to a literal TAB (awk -v escape bug)" || ok "win-path: no TAB corruption from backslashes"
printf '%s' "$WDEC" | grep -qF '\' && no "win-path: a raw backslash survived (un-normalized)" || ok "win-path: no raw backslashes remain"

echo "Test: floor does not pre-empt LLM retry (fires only at the boundary)"
reset
mk_proj "$FLOOR_PROJ"
cat > "$BRAIN_DIR/transcripts/fl2_poison_2026-05-24.txt" <<'TXEOF2'
--- session-meta ---
session_id: fl2
project_slug: poison
date: 2026-05-24
tool_count: 1
line_count: 7
---

USER: x
ASSISTANT:
  [Write] /work/src/c.ts
TXEOF2
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # 1st of 3 → retry, NOT floor
grep -q '"outcome":"retry"' "$STATE" 2>/dev/null && ok "floor: first failure is a retry (LLM not yet exhausted)" || no "floor: expected a retry on first failure"
grep -q '"reason":"deterministic-floor"' "$STATE" 2>/dev/null && no "floor: fired before MAX_FAILS (pre-empted LLM retry)" || ok "floor: did NOT fire before the quarantine boundary"
grep -q '\[auto-captured\]' "$FLOOR_PROJ" 2>/dev/null && no "floor: wrote a decision before exhausting LLM retry" || ok "floor: no premature PROJECT.md write"

echo "Test: floor on a no-edit transcript still quarantines (no false ok)"
reset
cat > "$BRAIN_DIR/transcripts/fl3_poison_2026-05-24.txt" <<'TXEOF3'
--- session-meta ---
session_id: fl3
project_slug: poison
date: 2026-05-24
tool_count: 0
line_count: 7
---

USER: just a chat
ASSISTANT:
  some discussion, no file changes here
TXEOF3
SB_DRAIN_MAX_FAILS=1 bash "$DRAIN" >/dev/null 2>&1 || true
eq "floor: no-edit transcript quarantines as error" "$(grep -c '"outcome":"error"' "$STATE" 2>/dev/null)" "1"
grep -q '"reason":"deterministic-floor"' "$STATE" 2>/dev/null && no "floor: falsely floored a no-edit transcript" || ok "floor: did not falsely floor a no-edit transcript"
unset CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR

# Ledger GC (state hygiene): the append-only .extraction-state.jsonl done-set must drop
# rows whose transcript basename no longer exists under transcripts/ (pruned by the archive
# cap), and keep rows whose transcript is still live. The live row here is pre-marked done
# so the batch loop skips it (sb_extraction_done) and the GC is what's under test.
echo "Test: ledger GC drops dead rows, keeps live rows"
reset
mk_tx "live_proj_2026-05-24.txt" proj
printf '{"basename":"live_proj_2026-05-24.txt","ts":"x","outcome":"ok"}\n{"basename":"gone_proj_2026-05-24.txt","ts":"x","outcome":"ok"}\n' > "$STATE"
bash "$DRAIN" >/dev/null 2>&1 || true
grep -q '"basename":"live_proj_2026-05-24.txt"' "$STATE" 2>/dev/null && ok "ledger GC kept the live row" || no "ledger GC dropped a live row"
grep -q '"basename":"gone_proj_2026-05-24.txt"' "$STATE" 2>/dev/null && no "ledger GC kept a dead row (orphan)" || ok "ledger GC dropped the dead row"

# ==== R2-B (0.56.0): line-cursor delta drain ====================================================
# The stub records "<basename> <from> <to>" per call and fails when "<basename> <from>" is listed
# in $RFAIL. Rows are checked on the done-set; cursors through the real sb_drain_cursor_map.
echo "Test: R2-B delta drain"
RLOG="$SANDBOX/rstub.log"; RFAIL="$SANDBOX/rstub.fail"
RSTUB="$SANDBOX/rstub.sh"
cat > "$RSTUB" <<EOF6
#!/bin/bash
printf '%s %s %s\n' "\${1##*/}" "\${3:-}" "\${4:-}" >> "$RLOG"
[ -f "$RFAIL" ] && grep -qxF "\${1##*/} \${3:-}" "$RFAIL" && exit 1
exit 0
EOF6
chmod +x "$RSTUB"
mk_lines() {  # $1 = archive name, $2 = body lines to append (the 7-line meta header comes first)
  local f="$BRAIN_DIR/transcripts/$1" i=1
  [ -f "$f" ] || printf -- '--- session-meta ---\nsession_id: %s\nproject_slug: proj\ndate: 2026-05-24\ntool_count: 1\nline_count: 0\n---\n' "${1%%_*}" > "$f"
  while [ "$i" -le "$2" ]; do printf 'USER: line %s of %s\n' "$i" "$1" >> "$f"; i=$((i+1)); done
}
rcalls() { if [ -f "$RLOG" ]; then grep -c . "$RLOG" || true; else echo 0; fi; }
rlast() { tail -1 "$RLOG" 2>/dev/null; }
rdrain() { SB_EXTRACT_STUB="$RSTUB" bash "$DRAIN" >/dev/null 2>&1 || true; }
cmap() {  # $1 = basename, $2 = field (2 cursor, 3 lines, 4 state) — the real accounting primitive
  # shellcheck disable=SC2016  # $1 expands inside the child shell
  BRAIN_DIR="$BRAIN_DIR" bash -c '. "$1/lib.sh"; sb_drain_cursor_map' _ "$SCRIPT_DIR" \
    | awk -F'\t' -v b="$1" -v k="$2" '$1 == b { print $k; exit }'
}
rows_for() { grep -F "\"basename\":\"$1\"" "$STATE" 2>/dev/null || true; }

# D1: a grown archive is re-queued with exactly the new window; no growth -> no call.
reset; rm -f "$RLOG" "$RFAIL"
mk_lines "gr1_proj_2026-05-24.txt" 3                       # 10 lines
rdrain
eq "delta: first drain extracts (0,10]" "$(rlast)" "gr1_proj_2026-05-24.txt 0 10"
rows_for gr1_proj_2026-05-24.txt | grep -q '"outcome":"ok".*"from":0,"lines":10' \
  && ok "delta: ok row carries from/lines" || no "delta: ok row lacks from/lines (got: $(rows_for gr1_proj_2026-05-24.txt))"
rm -f "$RLOG"; rdrain
eq "delta: no growth -> no extractor call" "$(rcalls)" "0"
mk_lines "gr1_proj_2026-05-24.txt" 4                       # 14 lines
rdrain
eq "delta: grown archive re-queued with the new window only" "$(rlast)" "gr1_proj_2026-05-24.txt 10 14"
eq "delta: cursor advanced to the new end" "$(cmap gr1_proj_2026-05-24.txt 2)" "14"

# D2: a failing region dead-letters ONLY that region; retry/error rows never advance the cursor.
reset; rm -f "$RLOG" "$RFAIL"
mk_lines "fr1_proj_2026-05-24.txt" 3; rdrain               # (0,10] ok
mk_lines "fr1_proj_2026-05-24.txt" 3                       # 13 lines
echo "fr1_proj_2026-05-24.txt 10" > "$RFAIL"
SB_DRAIN_MAX_FAILS=3 rdrain
rows_for fr1_proj_2026-05-24.txt | grep -q '"outcome":"retry","from":10,"lines":13' \
  && ok "dead-letter: a failed window records a retry row with from/lines" || no "dead-letter: no retry row for (10,13] (got: $(rows_for fr1_proj_2026-05-24.txt))"
eq "dead-letter: a retry row does not advance the cursor" "$(cmap fr1_proj_2026-05-24.txt 2)" "10"
SB_DRAIN_MAX_FAILS=3 rdrain; SB_DRAIN_FLOOR=off SB_DRAIN_MAX_FAILS=3 rdrain
rows_for fr1_proj_2026-05-24.txt | grep -q '"outcome":"error","from":10,"lines":13' \
  && ok "dead-letter: MAX_FAILS turns the region into an error row" || no "dead-letter: no error row (got: $(rows_for fr1_proj_2026-05-24.txt))"
eq "dead-letter: the error row does not advance the cursor" "$(cmap fr1_proj_2026-05-24.txt 2)" "10"
eq "dead-letter: the archive reads as dead" "$(cmap fr1_proj_2026-05-24.txt 4)" "dead"
N_BEFORE=$(rcalls); rdrain
eq "dead-letter: a dead region is not retried" "$(rcalls)" "$N_BEFORE"
mk_lines "fr1_proj_2026-05-24.txt" 3                       # 16 lines
rdrain
eq "dead-letter: growth past the dead region extracts only the new window" "$(rlast)" "fr1_proj_2026-05-24.txt 13 16"
eq "dead-letter: a later ok row lifts the cursor over the dead region" "$(cmap fr1_proj_2026-05-24.txt 2) $(cmap fr1_proj_2026-05-24.txt 4)" "16 done"

# D3: first-tick migration. Legacy row (no lines) + archive unchanged since -> baseline, no LLM;
# grown since -> legacy-regrow re-mined from the header end; legacy error unchanged -> stays dead.
reset; rm -f "$RLOG" "$RFAIL"
mk_lines "lb1_proj_2026-05-24.txt" 3; touch -t 202601010000 "$BRAIN_DIR/transcripts/lb1_proj_2026-05-24.txt"
mk_lines "le1_proj_2026-05-24.txt" 3; touch -t 202601010001 "$BRAIN_DIR/transcripts/le1_proj_2026-05-24.txt"
mk_lines "lr1_proj_2026-05-24.txt" 3                       # fresh mtime: grew after its legacy row
{
  printf '%s\n' '{"basename":"lb1_proj_2026-05-24.txt","ts":"2026-01-03T00:00:00Z","outcome":"ok"}'
  printf '%s\n' '{"basename":"le1_proj_2026-05-24.txt","ts":"2026-01-03T00:00:00Z","outcome":"error","fails":3}'
  printf '%s\n' '{"basename":"lr1_proj_2026-05-24.txt","ts":"2026-01-03T00:00:00Z","outcome":"ok"}'
} > "$STATE"
rdrain
rows_for lb1_proj_2026-05-24.txt | grep -q '"outcome":"baseline","reason":"cursor-baseline","from":0,"lines":10' \
  && ok "migration: unchanged legacy ok -> cursor-baseline row" || no "migration: no baseline row (got: $(rows_for lb1_proj_2026-05-24.txt))"
grep -q '^lb1_proj' "$RLOG" 2>/dev/null && no "migration: a baseline archive was sent to the extractor" || ok "migration: baseline costs no LLM call"
rows_for le1_proj_2026-05-24.txt | grep -q '"outcome":"error","reason":"legacy-dead-letter","from":0,"lines":10' \
  && ok "migration: unchanged legacy error stays dead-lettered (never baselined)" || no "migration: legacy error mishandled (got: $(rows_for le1_proj_2026-05-24.txt))"
eq "migration: legacy error is not extracted" "$(grep -c '^le1_proj' "$RLOG" 2>/dev/null || true)" "0"
eq "migration: grown legacy archive re-mined from the header end" "$(grep '^lr1_proj' "$RLOG" 2>/dev/null)" "lr1_proj_2026-05-24.txt 0 10"
rows_for lr1_proj_2026-05-24.txt | grep -q '"outcome":"ok","reason":"legacy-regrow","from":0,"lines":10' \
  && ok "migration: regrow row tagged legacy-regrow" || no "migration: regrow row missing (got: $(rows_for lr1_proj_2026-05-24.txt))"
# The migration is LLM-free, so it also runs on a DEFERRED tick (an always-on session must not
# leave a fresh upgrade reading every legacy archive as pending for hours).
reset; rm -f "$RLOG"
mk_lines "ld1_proj_2026-05-24.txt" 3; touch -t 202601010000 "$BRAIN_DIR/transcripts/ld1_proj_2026-05-24.txt"
printf '%s\n' '{"basename":"ld1_proj_2026-05-24.txt","ts":"2026-01-03T00:00:00Z","outcome":"ok"}' > "$STATE"
rm -f "$BRAIN_DIR/.drain-defer-count"
# STALE_MAX huge: the backdated archive must not trigger the age escape — this tick has to DEFER.
SB_INTERACTIVE_OVERRIDE=active SB_DRAIN_STALE_MAX=999999999 rdrain
eq "migration: the tick really deferred" "$(cat "$BRAIN_DIR/.drain-defer-count" 2>/dev/null)" "1"
grep -q '"basename":"ld1_proj_2026-05-24.txt".*"outcome":"baseline"' "$STATE" \
  && ok "migration: baseline written on a deferred tick" || no "migration: deferred tick skipped the LLM-free migration"
eq "migration: a deferred tick makes no extractor call" "$(rcalls)" "0"

# D4: CRLF archive — the window ends at wc -l; nothing is re-sent next tick.
reset; rm -f "$RLOG"
printf '%s\r\n' '--- session-meta ---' 'session_id: cr1' 'project_slug: proj' '---' 'USER: a' 'ASSISTANT: b' 'USER: c' \
  > "$BRAIN_DIR/transcripts/cr1_proj_2026-05-24.txt"
rdrain
eq "crlf: window (0,7]" "$(rlast)" "cr1_proj_2026-05-24.txt 0 7"
rm -f "$RLOG"; rdrain
eq "crlf: no re-send after the cursor reached the end" "$(rcalls)" "0"

# D5: no trailing newline — the torn last line is not covered until it is completed.
reset; rm -f "$RLOG"
mk_lines "nt1_proj_2026-05-24.txt" 3; printf 'USER: still typ' >> "$BRAIN_DIR/transcripts/nt1_proj_2026-05-24.txt"
rdrain
eq "torn: window stops before the torn line" "$(rlast)" "nt1_proj_2026-05-24.txt 0 10"
printf 'ing\n' >> "$BRAIN_DIR/transcripts/nt1_proj_2026-05-24.txt"
rdrain
eq "torn: the completed line is extracted next tick" "$(rlast)" "nt1_proj_2026-05-24.txt 10 11"

# D6: a recreated archive (line count below its rows) restarts at 0, and growth past the OLD
# cursor is not skipped (the stale rows are purged, not just masked).
reset; rm -f "$RLOG"
mk_lines "rc1_proj_2026-05-24.txt" 3                       # 10 lines
printf '%s\n' '{"basename":"rc1_proj_2026-05-24.txt","ts":"2026-05-24T00:00:00Z","outcome":"ok","from":0,"lines":50}' > "$STATE"
rdrain
eq "recreate: extraction restarts at 0" "$(rlast)" "rc1_proj_2026-05-24.txt 0 10"
rows_for rc1_proj_2026-05-24.txt | grep -q '"lines":50' && no "recreate: the stale cursor row survived" || ok "recreate: stale rows purged"
mk_lines "rc1_proj_2026-05-24.txt" 50                      # 60 lines: past the old cursor
rdrain
eq "recreate: growth past the old cursor is extracted, not skipped" "$(rlast)" "rc1_proj_2026-05-24.txt 10 60"

# D7: eligibility — >= SB_DRAIN_DELTA_MIN_BYTES new, or quiet >= SB_DRAIN_QUIET_S; a settled tiny
# tail gets an ok/too-small row WITH lines (so it is done) and no LLM call.
reset; rm -f "$RLOG"
mk_lines "el1_proj_2026-05-24.txt" 2                       # fresh, ~50 B new
SB_DRAIN_QUIET_S=3600 rdrain
eq "eligible: a small fresh window waits (no call, no row)" "$(rcalls) $(rows_for el1_proj_2026-05-24.txt | grep -c . || true)" "0 0"
mk_lines "el1_proj_2026-05-24.txt" 200                     # fresh, > 4 KB new
SB_DRAIN_QUIET_S=3600 rdrain
eq "eligible: >= 4 KB new is extracted while the archive is live" "$(rlast)" "el1_proj_2026-05-24.txt 0 209"
mk_lines "el2_proj_2026-05-24.txt" 2; touch -t 202601010000 "$BRAIN_DIR/transcripts/el2_proj_2026-05-24.txt"
SB_DRAIN_QUIET_S=3600 SB_DRAIN_MIN_BYTES=1024 rdrain
rows_for el2_proj_2026-05-24.txt | grep -q '"outcome":"ok","reason":"too-small","from":0,"lines":9' \
  && ok "eligible: a settled tiny tail -> ok/too-small row with lines" || no "eligible: too-small row wrong (got: $(rows_for el2_proj_2026-05-24.txt))"
grep -q '^el2_proj' "$RLOG" && no "eligible: the too-small tail was sent to the extractor" || ok "eligible: too-small costs no LLM call"
eq "eligible: a too-small archive is done" "$(cmap el2_proj_2026-05-24.txt 4)" "done"

# D8: chunk forward inside a tick — every chunk is one extractor call and one batch slot.
reset; rm -f "$RLOG"
mk_lines "ch1_proj_2026-05-24.txt" 30                      # 37 lines: body lines 1-9 are 40 B, 10-30 are 41 B
SB_EXTRACT_MAX_BYTES=320 SB_DRAIN_BATCH=2 rdrain
eq "chunks: two batch slots -> two forward chunks" "$(tr '\n' '|' < "$RLOG")" "ch1_proj_2026-05-24.txt 0 15|ch1_proj_2026-05-24.txt 15 22|"
SB_EXTRACT_MAX_BYTES=320 SB_DRAIN_BATCH=5 rdrain
eq "chunks: the next tick resumes at the cursor" "$(sed -n 3p "$RLOG")" "ch1_proj_2026-05-24.txt 22 29"
eq "chunks: the archive drains fully across ticks" "$(cmap ch1_proj_2026-05-24.txt 4)" "done"

# D8b: a FAILED attempt takes a batch slot too — the lock-budget proof (lib.sh, timeout_s comment)
# assumes at most SB_DRAIN_BATCH extractor calls per tick, failures included.
reset; rm -f "$RLOG" "$RFAIL"
for n in 1 2 3; do mk_lines "bf${n}_proj_2026-05-24.txt" 3; echo "bf${n}_proj_2026-05-24.txt 0" >> "$RFAIL"; done
SB_DRAIN_BATCH=2 SB_DRAIN_MAX_FAILS=3 rdrain
eq "batch: failing attempts are bounded by SB_DRAIN_BATCH" "$(rcalls)" "2"
rm -f "$RFAIL"

# D9: reconcile counts a GROWN archive as pending (the basename set called it done).
reset; rm -f "$RLOG" "$BRAIN_DIR/audit-log.jsonl"
mk_lines "rp1_proj_2026-05-24.txt" 3; rdrain
mk_lines "rp1_proj_2026-05-24.txt" 3
SB_DRAIN_BATCH=0 rdrain
RROW=$(grep 'reconcile' "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null | tail -1)
printf '%s' "$RROW" | grep -q 'declared=1 observed=0 pending=1' \
  && ok "reconcile: a grown archive is pending" || no "reconcile: grown archive miscounted (got: $RROW)"

# D10 (R2-F#10): the tick's ledger GC compacts a live archive's window rows to the rows the cursor
# map reads (lossless: same cursor and state), so the ledger stops growing by a row per window.
reset; rm -f "$RLOG"
mk_lines "cp1_proj_2026-05-24.txt" 8                       # 15 lines, extracted in five windows
for w in 0 3 6 9 12; do
  printf '{"basename":"cp1_proj_2026-05-24.txt","ts":"2026-05-24T00:00:00Z","outcome":"ok","from":%d,"lines":%d}\n' "$w" $((w + 3))
done > "$STATE"
CP_BEFORE="$(cmap cp1_proj_2026-05-24.txt 2) $(cmap cp1_proj_2026-05-24.txt 4)"
eq "compact: fixture is a done archive" "$CP_BEFORE" "15 done"
SB_DRAIN_BATCH=0 rdrain
eq "compact: the tick's GC keeps one row for the done archive" "$(rows_for cp1_proj_2026-05-24.txt | grep -c . || true)" "1"
eq "compact: cursor and state unchanged by the compaction" "$(cmap cp1_proj_2026-05-24.txt 2) $(cmap cp1_proj_2026-05-24.txt 4)" "$CP_BEFORE"
eq "compact: a done archive makes no extractor call" "$(rcalls)" "0"

# D11 (R2-F#4/#5): archives written before 0.56.0 hold secrets in clear. The first ticks scrub
# them in place (sb_scrub_archive_file), under the drain lock and before the defer gate, pending
# archives first, SB_DRAIN_BATCH per tick, then write .archive-scrub-v1. No archive is extracted
# before its scrub: the extractor never receives a key. The stub records the window it receives.
SSTUB="$SANDBOX/sstub.sh"; SCAP="$SANDBOX/sstub.cap"
cat > "$SSTUB" <<EOF7
#!/bin/bash
printf '=== %s %s %s\n' "\${1##*/}" "\$3" "\$4" >> "$SCAP"
sed -n "\$((\$3 + 1)),\$4p" "\$1" >> "$SCAP"
exit 0
EOF7
chmod +x "$SSTUB"
sdrain() { SB_EXTRACT_STUB="$SSTUB" bash "$DRAIN" >/dev/null 2>&1 || true; }
SMARK="$BRAIN_DIR/.archive-scrub-v1"; STODO="$BRAIN_DIR/.archive-scrub-v1.todo"
KANT="sk-""ant-api03-$(printf 'Zq9x%.0s' 1 2 3 4 5 6 7 8)"   # built at run time: no key-shaped literal in the repo
mk_key() {  # $1 = archive, $2 = touch stamp: an archive written before 0.56.0, a key in clear
  mk_lines "$1" 3; printf 'USER: my key is %s\n' "$KANT" >> "$BRAIN_DIR/transcripts/$1"; mk_lines "$1" 2
  touch -t "$2" "$BRAIN_DIR/transcripts/$1"
}
smt() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
# D11a: a legacy archive (legacy ok row, grown since: re-mined) goes through migration then extraction
reset; rm -f "$SCAP" "$SMARK" "$STODO"
mk_key "sk1_proj_2026-05-24.txt" 202605240000
SK1="$BRAIN_DIR/transcripts/sk1_proj_2026-05-24.txt"; SK1_LC=$(wc -l < "$SK1"); SK1_MT=$(smt "$SK1")
printf '%s\n' '{"basename":"sk1_proj_2026-05-24.txt","ts":"2026-01-01T00:00:00Z","outcome":"ok"}' > "$STATE"
sdrain
grep -q '^=== sk1_proj_2026-05-24.txt 0 ' "$SCAP" 2>/dev/null && ok "scrub-migrate: the legacy archive was extracted" \
  || no "scrub-migrate: the legacy archive was not extracted (got: $(cat "$SCAP" 2>/dev/null))"
grep -qF 'sk-ant-' "$SCAP" 2>/dev/null && no "scrub-migrate: the extractor RECEIVED the key" || ok "scrub-migrate: the extractor never received the key"
grep -qF '[redacted:anthropic]' "$SCAP" 2>/dev/null && ok "scrub-migrate: the extractor received the redaction" || no "scrub-migrate: no redaction in the extractor input"
grep -qF 'sk-ant-' "$SK1" && no "scrub-migrate: the archive at rest still holds the key" || ok "scrub-migrate: the archive at rest is scrubbed"
eq "scrub-migrate: line count unchanged" "$(wc -l < "$SK1")" "$SK1_LC"
eq "scrub-migrate: mtime unchanged (the quiet rule reads it)" "$(smt "$SK1")" "$SK1_MT"
[ -f "$SMARK" ] && [ ! -f "$STODO" ] && ok "scrub-migrate: done in one tick -> marker, no to-do list" || no "scrub-migrate: marker/to-do state wrong"
# D11b: an archive whose scrub fails this tick (its lock is held) is NOT extracted, even with free slots
reset; rm -f "$SCAP" "$SMARK" "$STODO"
mk_key "sg1_proj_2026-05-24.txt" 202605240000
printf '1\n' > "$BRAIN_DIR/transcripts/.sg1_proj_2026-05-24.txt.lock"
SB_DRAIN_BATCH=3 sdrain
grep -q '^=== sg1_proj' "$SCAP" 2>/dev/null && no "scrub-migrate: an archive still awaiting its scrub was extracted" \
  || ok "scrub-migrate: an archive awaiting its scrub is not extracted"
grep -qx 'sg1_proj_2026-05-24.txt' "$STODO" 2>/dev/null && ok "scrub-migrate: the failed scrub stays on the to-do list" || no "scrub-migrate: the failed scrub left the to-do list"
[ ! -f "$SMARK" ] && ok "scrub-migrate: no marker while an archive awaits its scrub" || no "scrub-migrate: marker written early"
rm -f "$BRAIN_DIR/transcripts/.sg1_proj_2026-05-24.txt.lock"
SB_DRAIN_BATCH=3 sdrain
grep -q '^=== sg1_proj' "$SCAP" 2>/dev/null && ok "scrub-migrate: extracted once scrubbed (next tick)" || no "scrub-migrate: never extracted after its scrub"
grep -qF 'sk-ant-' "$SCAP" 2>/dev/null && no "scrub-migrate: key leaked after the retry" || ok "scrub-migrate: no key after the retry either"
[ -f "$SMARK" ] && ok "scrub-migrate: marker once the list is empty" || no "scrub-migrate: no marker after the last scrub"
# D11c: SB_DRAIN_BATCH scrubs per tick, PENDING archives first (a done archive can wait; the
# extractor cannot): with a batch of 1, the pending archive is scrubbed and extracted on tick 1
reset; rm -f "$SCAP" "$SMARK" "$STODO"
mk_key "so0_proj_2026-05-24.txt" 202605230000              # done, oldest, first in name order
mk_key "so1_proj_2026-05-24.txt" 202605240000              # pending
printf '{"basename":"so0_proj_2026-05-24.txt","ts":"2026-05-24T00:00:00Z","outcome":"ok","from":0,"lines":%d}\n' \
  "$(wc -l < "$BRAIN_DIR/transcripts/so0_proj_2026-05-24.txt")" > "$STATE"
SB_DRAIN_BATCH=1 sdrain
grep -q '^=== so1_proj' "$SCAP" 2>/dev/null && ok "scrub-migrate: the pending archive is scrubbed first and extracted on tick 1" \
  || no "scrub-migrate: the pending archive waited behind a done one"
grep -qx 'so0_proj_2026-05-24.txt' "$STODO" 2>/dev/null && ok "scrub-migrate: batch-bounded (the done archive waits for tick 2)" || no "scrub-migrate: not batch-bounded"
SB_DRAIN_BATCH=1 sdrain
grep -qF 'sk-ant-' "$BRAIN_DIR/transcripts/so0_proj_2026-05-24.txt" && no "scrub-migrate: the done archive was never scrubbed" || ok "scrub-migrate: resumed on tick 2 (done archive scrubbed)"
[ -f "$SMARK" ] && [ ! -f "$STODO" ] && ok "scrub-migrate: complete after tick 2" || no "scrub-migrate: not complete after tick 2"
# D11d: the migration is LLM-free, so it also runs on a DEFERRED tick
reset; rm -f "$SCAP" "$SMARK" "$STODO" "$BRAIN_DIR/.drain-defer-count"
mk_key "sd1_proj_2026-05-24.txt" 202605240000
SB_INTERACTIVE_OVERRIDE=active SB_DRAIN_STALE_MAX=999999999 sdrain
eq "scrub-migrate: the tick really deferred" "$(cat "$BRAIN_DIR/.drain-defer-count" 2>/dev/null)" "1"
grep -qF 'sk-ant-' "$BRAIN_DIR/transcripts/sd1_proj_2026-05-24.txt" && no "scrub-migrate: a deferred tick skipped the scrub" || ok "scrub-migrate: runs on a deferred tick"

# Test GC (R1.2): stale extraction markers (7d) + nested-spawn scratch
# transcripts (3d) are swept by the drainer. Re-exports HOME — keep this LAST.
echo "Test: GC sweeps — stale markers + scratch transcripts"
reset
export HOME="$SANDBOX"            # hermetic: the scratch prune walks $HOME/.claude
touch -t 202601010000 "$BRAIN_DIR/.last-extracted-line-old--sess"
touch "$BRAIN_DIR/.last-extracted-line-new--sess"
touch -t 202601010000 "$BRAIN_DIR/.last-archived-line-old--sess"
touch "$BRAIN_DIR/.last-archived-line-new--sess"
mkdir -p "$HOME/.claude/projects/-x-second-brain-scratch"
touch -t 202601010000 "$HOME/.claude/projects/-x-second-brain-scratch/old.jsonl"
touch "$HOME/.claude/projects/-x-second-brain-scratch/new.jsonl"
bash "$DRAIN" >/dev/null 2>&1 || true
[ ! -f "$BRAIN_DIR/.last-extracted-line-old--sess" ] && ok "stale marker swept (7d)" || no "stale marker survived"
[ -f "$BRAIN_DIR/.last-extracted-line-new--sess" ] && ok "fresh marker kept" || no "fresh marker swept"
[ ! -f "$BRAIN_DIR/.last-archived-line-old--sess" ] && ok "stale raw_line cursor (.last-archived-line-*) swept (30d)" || no "stale .last-archived-line-* survived"
[ -f "$BRAIN_DIR/.last-archived-line-new--sess" ] && ok "fresh raw_line cursor kept" || no "fresh .last-archived-line-* swept"
[ ! -f "$HOME/.claude/projects/-x-second-brain-scratch/old.jsonl" ] && ok "old scratch transcript pruned (3d)" || no "old scratch transcript survived"
[ -f "$HOME/.claude/projects/-x-second-brain-scratch/new.jsonl" ] && ok "fresh scratch transcript kept" || no "fresh scratch transcript pruned"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

# Test GC-2 (R4, SCRIPTS-05): retention GC (sb-prune-archives) runs WITHOUT the
# auto_improve opt-in — a *.bak past bak_ttl_days is pruned on a default config.
printf '{"auto_improve": false, "retention": {"bak_ttl_days": 14}}\n' > "$BRAIN_DIR/config.json"
touch -t 202601010000 "$BRAIN_DIR/stale-rescue.bak"
touch "$BRAIN_DIR/fresh-rescue.bak"
bash "$DRAIN" >/dev/null 2>&1 || true
[ ! -f "$BRAIN_DIR/stale-rescue.bak" ] && ok "stale .bak pruned without auto_improve" || no "stale .bak survived (retention GC still gated)"
[ -f "$BRAIN_DIR/fresh-rescue.bak" ] && ok "fresh .bak kept" || no "fresh .bak wrongly pruned"
rm -f "$BRAIN_DIR/config.json" "$BRAIN_DIR/fresh-rescue.bak"

echo ""
echo "Results R4: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

# Test codemap regen block (P3a Task C2): the drainer resolves the target repo from
# the registry (newest last_session_iso), invokes the code-map CLI bundle via node,
# and honors the auto_codemap:false kill switch. Bundle + node are FAKED (a marker-
# writing `node` shadowing the real one via PATH; an empty file at the bundle path
# under a sandbox CLAUDE_PLUGIN_ROOT) so no real regen runs. auto_improve and
# auto_maintain are disabled so no OTHER block can touch the fake node marker.
echo "Test: codemap regen block targets the newest registry repo via the CLI"
reset
CMROOT="$SANDBOX/plugroot"; mkdir -p "$CMROOT/mcp/dist/tools"
: > "$CMROOT/mcp/dist/tools/code-map-cli.bundle.js"
CMREPO="$SANDBOX/cmrepo"; mkdir -p "$CMREPO"
printf '{"slug":"older","root_path":"/definitely/not/this","last_session_iso":"2026-01-01T00:00:00Z"}\n{"slug":"cmproj","root_path":"%s","last_session_iso":"2026-07-01T00:00:00Z"}\n' \
  "$CMREPO" > "$BRAIN_DIR/projects.jsonl"
printf '{"auto_improve": false, "auto_maintain": false}\n' > "$BRAIN_DIR/config.json"
CM_MARKER="$SANDBOX/cm-called"; rm -f "$CM_MARKER"
NODEDIR="$SANDBOX/fakenode"; mkdir -p "$NODEDIR"
cat > "$NODEDIR/node" <<EOF5
#!/bin/bash
printf 'args=%s project_dir=%s\n' "\$*" "\${CLAUDE_PROJECT_DIR:-}" >> "$CM_MARKER"
exit 0
EOF5
chmod +x "$NODEDIR/node"
SB_BRAIN_OS=on CLAUDE_PLUGIN_ROOT="$CMROOT" PATH="$NODEDIR:$PATH" bash "$DRAIN" >/dev/null 2>&1 || true
grep -qF 'code-map-cli.bundle.js' "$CM_MARKER" 2>/dev/null \
  && ok "codemap block invoked the CLI bundle via node" || no "codemap CLI not invoked"
grep -qF "project_dir=$CMREPO" "$CM_MARKER" 2>/dev/null \
  && ok "codemap targeted the newest registry root_path" || no "codemap target repo wrong (got: $(cat "$CM_MARKER" 2>/dev/null))"
# Kill switch: auto_codemap:false must gate the whole block off (no CLI spawn).
rm -f "$CM_MARKER"
printf '{"auto_improve": false, "auto_maintain": false, "auto_codemap": false}\n' > "$BRAIN_DIR/config.json"
SB_BRAIN_OS=on CLAUDE_PLUGIN_ROOT="$CMROOT" PATH="$NODEDIR:$PATH" bash "$DRAIN" >/dev/null 2>&1 || true
[ ! -f "$CM_MARKER" ] && ok "auto_codemap:false gates the regen off" || no "codemap ran despite auto_codemap:false"
printf '{"auto_improve": false, "auto_maintain": false}\n' > "$BRAIN_DIR/config.json"

# Loud-failure path (skeptic-review must-fix): the CLI is fail-soft (always
# exit 0, failures reported as 'code-map: ERROR ...' on stderr), so the drainer
# must match that marker in captured stderr — a bare `||` never fires. Fake
# node emits the marker; require the ec=1 error-log line.
cat > "$NODEDIR/node" <<EOF5
#!/bin/bash
echo 'code-map: ERROR simulated store write failure' >&2
exit 0
EOF5
chmod +x "$NODEDIR/node"
rm -f "$BRAIN_DIR/error-log.jsonl"
SB_BRAIN_OS=on CLAUDE_PLUGIN_ROOT="$CMROOT" PATH="$NODEDIR:$PATH" bash "$DRAIN" >/dev/null 2>&1 || true
grep -q 'codemap regen failed' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null \
  && ok "fail-soft CLI ERROR marker surfaces as a LOUD error-log line" \
  || no "CLI 'code-map: ERROR' was swallowed (dead-|| regression)"

# Corrupt-registry tolerance (skeptic-review fix): one garbage line must not
# kill the slurp — the newest VALID record WITH a root_path still wins (the
# newest overall record here lacks root_path and must be skipped, not block).
cat > "$NODEDIR/node" <<EOF5
#!/bin/bash
printf 'project_dir=%s\n' "\${CLAUDE_PROJECT_DIR:-}" >> "$CM_MARKER"
exit 0
EOF5
chmod +x "$NODEDIR/node"
rm -f "$CM_MARKER"
printf 'GARBAGE NOT JSON\n{"slug":"cmproj","root_path":"%s","last_session_iso":"2026-07-01T00:00:00Z"}\n{"slug":"newest-but-unmappable","last_session_iso":"2026-07-02T00:00:00Z"}\n' \
  "$CMREPO" > "$BRAIN_DIR/projects.jsonl"
SB_BRAIN_OS=on CLAUDE_PLUGIN_ROOT="$CMROOT" PATH="$NODEDIR:$PATH" bash "$DRAIN" >/dev/null 2>&1 || true
grep -qF "project_dir=$CMREPO" "$CM_MARKER" 2>/dev/null \
  && ok "garbage line tolerated; newest record WITH root_path targeted" \
  || no "corrupt registry killed the codemap target resolution (got: $(cat "$CM_MARKER" 2>/dev/null))"
rm -f "$BRAIN_DIR/config.json"

# --- Observation-ledger GC (P0 rec 5): >7-day-old per-session ledgers swept,
# fresh ones kept. touch -t sets an old mtime portably (GNU + BSD).
reset
mkdir -p "$BRAIN_DIR/observations"
printf '{"ts":"2026-01-01T00:00:00Z","tool":"Bash","target":"x","ok":true}\n' > "$BRAIN_DIR/observations/old-session.jsonl"
touch -t 202601010000 "$BRAIN_DIR/observations/old-session.jsonl"
printf '{"ts":"2026-07-30T00:00:00Z","tool":"Bash","target":"y","ok":true}\n' > "$BRAIN_DIR/observations/fresh-session.jsonl"
bash "$DRAIN" >/dev/null 2>&1 || true
[ ! -f "$BRAIN_DIR/observations/old-session.jsonl" ] \
  && ok "observation GC: >7d ledger swept" \
  || no "observation GC: old ledger survived"
[ -f "$BRAIN_DIR/observations/fresh-session.jsonl" ] \
  && ok "observation GC: fresh ledger kept" \
  || no "observation GC: fresh ledger was deleted"

# --- lock steal must clear a NON-EMPTY stale lock dir ------------------------
# The steal path itself writes $LOCK_DIR/pid, so any run killed after that point
# (sleep, SIGKILL, session teardown — the EXIT trap never fires) leaves the dir
# non-empty. rmdir cannot remove a non-empty dir, mkdir then fails, and the run
# exits 0: the scheduler fires forever while draining nothing, and queued
# transcripts age out of the eviction cap un-mined. The steal must remove
# whatever a dead run left behind. Staleness is overridden here only to REACH
# the steal branch; the mechanism under test is the clear itself.
LOCK="$BRAIN_DIR/.extract-drain.lock.d"
mkdir -p "$LOCK"; echo "99999" > "$LOCK/pid"
sleep 2
SB_DRAIN_FORCE_MKDIR_LOCK=1 SB_DRAIN_LOCK_STALE=1 SB_EXTRACT_STUB="$STUB" \
  bash "$DRAIN" >/dev/null 2>&1 || true
if [ "$(cat "$LOCK/pid" 2>/dev/null)" = "99999" ]; then
  no "lock steal: dead run's non-empty lock dir still wedged (pid 99999 survives)"
else
  ok "lock steal: non-empty stale lock cleared, drainer proceeded"
fi
rm -rf "$LOCK" 2>/dev/null || true

# --- P8 reconciliation (0.48.0): silence-latency stamp + declared-vs-observed row ---
# produced-at = archive mtime (backdated via touch -t), captured-at = ledger ts; the
# ok row must carry latency_s >= the backdate gap, and every tick must leave ONE
# gate=drain-tick verdict=reconcile audit row with declared/observed/pending fields.
reset
rm -f "$BRAIN_DIR/audit-log.jsonl"
mk_tx "lat1_proj_2026-05-24.txt" proj
touch -t 202605240000 "$BRAIN_DIR/transcripts/lat1_proj_2026-05-24.txt"
SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
LAT=$(grep '"basename":"lat1_proj_2026-05-24.txt"' "$STATE" 2>/dev/null | grep -o '"latency_s":[0-9]*' | cut -d: -f2 | head -1)
if [ -n "$LAT" ] && [ "$LAT" -ge 7200 ]; then
  ok "reconcile: ok row carries latency_s from backdated archive mtime ($LAT s)"
else
  no "reconcile: latency_s missing or below backdate gap (got '${LAT:-none}')"
fi
RROW=$(grep 'reconcile' "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null | tail -1)
printf '%s' "$RROW" | grep -q 'declared=1' && printf '%s' "$RROW" | grep -q 'observed=1' \
  && printf '%s' "$RROW" | grep -q 'pending=0' \
  && ok "reconcile: audit row declared=1 observed=1 pending=0 after full drain" \
  || no "reconcile: audit row wrong after full drain (got: $RROW)"

# A queued-but-unprocessed transcript must show up as pending with a real oldest age.
mk_tx "lat2_proj_2026-05-24.txt" proj
touch -t 202605240000 "$BRAIN_DIR/transcripts/lat2_proj_2026-05-24.txt"
SB_DRAIN_BATCH=0 bash "$DRAIN" >/dev/null 2>&1 || true
RROW=$(grep 'reconcile' "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null | tail -1)
printf '%s' "$RROW" | grep -q 'pending=1' \
  || no "reconcile: expected pending=1 with a queued transcript (got: $RROW)"
ROLD=$(printf '%s' "$RROW" | grep -oE 'oldest_pending_s=[0-9]+' | cut -d= -f2)
if [ -n "$ROLD" ] && [ "$ROLD" -ge 7200 ]; then
  ok "reconcile: pending=1 with oldest_pending_s from the backdated queue ($ROLD s)"
else
  no "reconcile: oldest_pending_s missing or below backdate gap (got '${ROLD:-none}')"
fi

# A retry (transient, non-terminal) row must count as PENDING, not observed —
# the reconcile stanza's terminal filter (ok|error) is the branch under test.
mk_tx "rt1_poison_2026-05-24.txt" poison
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # 1st failure -> retry row
grep -q '"basename":"rt1_poison_2026-05-24.txt","ts":[^,]*,"outcome":"retry"' "$STATE" 2>/dev/null \
  || grep -q '"basename":"rt1_poison_2026-05-24.txt"' "$STATE" 2>/dev/null \
  || no "reconcile-retry: expected a retry row for the poison transcript"
RROW=$(grep 'reconcile' "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null | tail -1)
# This tick drains lat2 (ok) and retries rt1 → declared=3 observed=2 pending=1:
# the retry row must NOT count as observed.
printf '%s' "$RROW" | grep -q 'observed=2' && printf '%s' "$RROW" | grep -q 'pending=1' \
  && ok "reconcile: a retry row stays PENDING (not observed)" \
  || no "reconcile: retry row miscounted — expected observed=2 pending=1, got: $RROW"

# --- D215: the real POSIX pgrep interactive-detection branch, unpinned -----
# Every case above sets SB_INTERACTIVE_OVERRIDE, which short-circuits
# sb_drain_should_defer BEFORE the `pgrep -u $(id -u) -x claude` loop ever
# runs — so that loop (and the -p arg-filter inside it) had no behavioral
# coverage anywhere in the suite. Fake `pgrep`/`ps` binaries ahead of the real
# ones on PATH exercise it for real, with SB_INTERACTIVE_OVERRIDE unset.
FAKE_BIN="$SANDBOX/fakebin"; mkdir -p "$FAKE_BIN"
REAL_PS=$(command -v ps || echo /bin/ps)
cat > "$FAKE_BIN/pgrep" <<EOF
#!/bin/bash
[ -f "$SANDBOX/.fake-pgrep-pids" ] && cat "$SANDBOX/.fake-pgrep-pids"
exit 0
EOF
chmod +x "$FAKE_BIN/pgrep"
cat > "$FAKE_BIN/ps" <<EOF
#!/bin/bash
if [ "\$1" = "-p" ]; then
  f="$SANDBOX/.fake-ps-args-\$2"
  [ -f "\$f" ] && cat "\$f"
  exit 0
fi
exec "$REAL_PS" "\$@"
EOF
chmod +x "$FAKE_BIN/ps"

# D215a: pgrep reports a live claude PID whose args carry NO "-p" (an
# interactive session) → the loop's default arm fires → defer, no processing.
reset; mk_tx "s1_proj_2026-05-24.txt" proj
echo "4242" > "$SANDBOX/.fake-pgrep-pids"
echo "claude" > "$SANDBOX/.fake-ps-args-4242"
( unset SB_INTERACTIVE_OVERRIDE
  PATH="$FAKE_BIN:$PATH" SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 ) || true
eq "pgrep: interactive claude (no -p) -> defer, no processing" "$(done_count)" "0"

# D215b: pgrep reports a live claude PID whose args DO carry "-p" (our own /
# another print-mode extractor) → the loop's "ignore" arm fires for every pid
# → falls through to `return 1` → no defer, processing proceeds.
reset; mk_tx "s1_proj_2026-05-24.txt" proj
echo "4242" > "$SANDBOX/.fake-pgrep-pids"
echo "claude -p --model sonnet" > "$SANDBOX/.fake-ps-args-4242"
( unset SB_INTERACTIVE_OVERRIDE
  PATH="$FAKE_BIN:$PATH" SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 ) || true
eq "pgrep: print-mode-only claude (-p) -> no defer, processes" "$(done_count)" "1"

# D215c: pgrep finds no claude pid at all -> loop body never runs -> no defer.
reset; mk_tx "s1_proj_2026-05-24.txt" proj
rm -f "$SANDBOX/.fake-pgrep-pids"
( unset SB_INTERACTIVE_OVERRIDE
  PATH="$FAKE_BIN:$PATH" SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 ) || true
eq "pgrep: no claude process -> no defer, processes" "$(done_count)" "1"

echo ""
echo "Results C2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
