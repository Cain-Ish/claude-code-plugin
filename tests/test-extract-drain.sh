#!/bin/bash
# Tests for extract-drain.sh
# run-all-timeout: 300   (31 full drainer ticks by design; ~3.8s/tick lib.sh-source floor on MSYS — see run-all.sh)
# shellcheck disable=SC2015  # `cond && ok || no`: ok/no always return 0, so || is never wrongly taken
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
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # 3rd → terminal error
RETRIES=$(grep -c '"outcome":"retry"' "$STATE" || echo 0)
ERRORS=$(grep -c '"outcome":"error"' "$STATE" || echo 0)
eq "poison: 2 retries recorded" "$RETRIES" "2"
eq "poison: 1 terminal error" "$ERRORS" "1"
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # must NOT touch it again
eq "poison: not reprocessed after terminal" "$(grep -c '"outcome":"retry"' "$STATE" || echo 0)" "2"

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
SB_EXTRACT_STUB="$FPSTUB" SB_DRAIN_MIN_BYTES=1024 bash "$DRAIN" >/dev/null 2>&1 || true
grep -q '"basename":"tiny1_x.txt"' "$STATE" 2>/dev/null && grep -q '"reason":"too-small"' "$STATE" 2>/dev/null \
  && ok "too-small archive marked ok/too-small in state" || no "too-small not recorded in state"
[ ! -f "$CALLED" ] && ok "extractor NOT spawned for too-small archive" || no "extractor was spawned for a too-small archive"
# Idempotent: second run must skip it via sb_extraction_done.
SB_EXTRACT_STUB="$FPSTUB" SB_DRAIN_MIN_BYTES=1024 bash "$DRAIN" >/dev/null 2>&1 || true
eq "too-small recorded exactly once" "$(grep -c '"basename":"tiny1_x.txt"' "$STATE" 2>/dev/null)" "1"
# Header guard (deep-review): a file WITHOUT the ^---$ terminator must NOT be
# fast-path-classified too-small (sed would report 0 bytes for real content).
printf 'no header here\nlots of real content that is not actually small at all\n' > "$BRAIN_DIR/transcripts/nohdr_x.txt"
SB_EXTRACT_STUB="$FPSTUB" SB_DRAIN_MIN_BYTES=1024 bash "$DRAIN" >/dev/null 2>&1 || true
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

# Test GC (R1.2): stale extraction markers (7d) + nested-spawn scratch
# transcripts (3d) are swept by the drainer. Re-exports HOME — keep this LAST.
echo "Test: GC sweeps — stale markers + scratch transcripts"
reset
export HOME="$SANDBOX"            # hermetic: the scratch prune walks $HOME/.claude
touch -t 202601010000 "$BRAIN_DIR/.last-extracted-line-old--sess"
touch "$BRAIN_DIR/.last-extracted-line-new--sess"
mkdir -p "$HOME/.claude/projects/-x-second-brain-scratch"
touch -t 202601010000 "$HOME/.claude/projects/-x-second-brain-scratch/old.jsonl"
touch "$HOME/.claude/projects/-x-second-brain-scratch/new.jsonl"
bash "$DRAIN" >/dev/null 2>&1 || true
[ ! -f "$BRAIN_DIR/.last-extracted-line-old--sess" ] && ok "stale marker swept (7d)" || no "stale marker survived"
[ -f "$BRAIN_DIR/.last-extracted-line-new--sess" ] && ok "fresh marker kept" || no "fresh marker swept"
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

echo ""
echo "Results C2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
