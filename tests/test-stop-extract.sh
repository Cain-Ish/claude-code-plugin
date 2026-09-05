#!/bin/bash
# pins: SB_EXTRACT — kill-switch test: asserts =off skips the LLM call but still archives + advances the marker (D077)
# Tests for scripts/stop-extract.sh — Stop-hook orchestrator that extracts
# run-all-timeout: 480   (18 full Stop-hook invocations by design; each ~13s on MSYS under load — spawn-bound lib.sh, see LC-11)
# session deltas from the conversation transcript and merges them into
# PROJECT.md + wiki via merge-project-update.sh.
#
# We stub the `claude` binary on PATH so tests run without a live LLM.
#
# Test isolation: when this runs INSIDE a Claude Code session (test author's
# local box), CLAUDECODE=1 is inherited and lib.sh:sb_call_extractor would
# short-circuit to status=queued, defeating the stubbed-claude flow. We unset
# it so the test exercises the production "out of session" / "stubbed CLI"
# path. (Pre-push hook + CI also typically have CLAUDECODE unset.)
unset CLAUDECODE
set -u
REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$REPO_ROOT/scripts/stop-extract.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() {
  echo "FAIL: $1"
  # Diagnostics for remote-CI failures (macOS job has no shell access):
  echo "── error-log:"; tail -5 "$SANDBOX/.second-brain/error-log.jsonl" 
  echo "── extractor-health:"; cat "$SANDBOX/.second-brain/extractor-health.json" 
  echo "── PROJECT.md:"; head -20 "$SANDBOX/.second-brain/projects/test-slug/PROJECT.md" 
  exit 1
}
pass() { echo "PASS: $1"; }

# Portable content hash: macOS ships shasum, not sha256sum (macOS CI job).
# A bare sha256sum would empty-string both sides under set -u and pass the
# "unchanged" assertions VACUOUSLY (R8 premise review).
content_hash() { sha256sum "$1"  | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }

init_sandbox() {
  local name="$1"
  SANDBOX="$TMP/$name"
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/.second-brain/projects/test-slug" \
           "$SANDBOX/knowledge/wiki" \
           "$SANDBOX/repo/test-slug" \
           "$SANDBOX/path-stub" \
           "$SANDBOX/transcript"
  export HOME="$SANDBOX"
  # Wiki lives under $HOME/knowledge/wiki since v1.0 (matches stop-extract.sh
  # default of CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge). The old
  # .second-brain/wiki path is legacy and only the projects/ subdir of
  # .second-brain is still used as the hot-tier home.
  cd "$SANDBOX/repo/test-slug" || fail "cd failed in $name"
  cat > "$SANDBOX/.second-brain/projects/test-slug/PROJECT.md" <<'EOF'
# PROJECT: test-slug

## Goal
seeded.

## State
seeded.

## Conventions
- conv 1

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: 2026-05-01T00:00:00Z -->
<!-- last_queried_wiki: -->
EOF
  cp "$SANDBOX/.second-brain/projects/test-slug/PROJECT.md" \
     "$SANDBOX/.second-brain/.session-baseline-test-slug.md"
}

seed_transcript_with_edit() {
  cat > "$SANDBOX/transcript/session.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/foo.ts","old_string":"a","new_string":"b"}}]}}
{"type":"user","message":{"role":"user","content":"thanks"}}
EOF
}

seed_transcript_with_mixed_paths() {
  # Mix of project paths and /tmp scratch — degraded fallback should strip /tmp.
  cat > "$SANDBOX/transcript/session.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/foo.ts","old_string":"a","new_string":"b"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/scratch.py","content":"x"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/var/tmp/staging.toml","old_string":"a","new_string":"b"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/run/user/1000/sock.py","old_string":"a","new_string":"b"}}]}}
{"type":"user","message":{"role":"user","content":"thanks"}}
EOF
}

seed_transcript_qna_only() {
  cat > "$SANDBOX/transcript/session.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}
EOF
}

stub_claude_json() {
  local payload="$1"
  cat > "$SANDBOX/path-stub/claude" <<EOF
#!/bin/bash
# Stub: ignores args and stdin, emits fixed JSON.
cat <<JSON
$payload
JSON
EOF
  chmod +x "$SANDBOX/path-stub/claude"
  export PATH="$SANDBOX/path-stub:$PATH"
}

stub_claude_garbage() {
  cat > "$SANDBOX/path-stub/claude" <<'EOF'
#!/bin/bash
echo "not valid json at all"
EOF
  chmod +x "$SANDBOX/path-stub/claude"
  export PATH="$SANDBOX/path-stub:$PATH"
}

stop_payload() {
  jq -nc --arg sid "${1:-test-session}" \
        --arg tp "$SANDBOX/transcript/session.jsonl" \
        --arg cwd "$SANDBOX/repo/test-slug" \
        '{session_id:$sid, transcript_path:$tp, cwd:$cwd, hook_event_name:"Stop"}'
}

ORIG_PATH="$PATH"
restore_path() { export PATH="$ORIG_PATH"; }

# --- Test 1: substantive transcript + claude returns valid JSON → merge fires.
init_sandbox "happy"
seed_transcript_with_edit
stub_claude_json '{"recent_decisions":["use Haiku for extraction"],"open_blockers":[],"cross_refs":["new-page"],"files_touched":["src/foo.ts"]}'
stop_payload | "$SCRIPT" >/dev/null 2>&1
PROJ="$SANDBOX/.second-brain/projects/test-slug/PROJECT.md"
grep -q "use Haiku for extraction" "$PROJ" || fail "happy: decision not merged into PROJECT.md"
grep -q "\[\[new-page\]\]" "$PROJ" || fail "happy: cross-ref not merged"
# Cross-ref stubs land under wiki/entities/ — merge-project-update.sh:269.
[ -f "$SANDBOX/knowledge/wiki/entities/new-page.md" ] || fail "happy: wiki stub not created at expected path"
pass "happy path: claude returns JSON → merge fires"
restore_path

# --- Test 1b: extractor relations[] land in edges.jsonl (capture-time graph).
# Both endpoints are created via cross_refs (which scaffold wiki/entities/<slug>.md),
# so the edge resolves and is asserted rather than quarantined.
init_sandbox "relations"
seed_transcript_with_edit
stub_claude_json '{"recent_decisions":[],"open_blockers":[],"cross_refs":["wg-tunnel","vps-ufw-depinned"],"files_touched":[],"relations":[{"from":"wg-tunnel","to":"vps-ufw-depinned","type":"requires","confidence":"high"}]}'
stop_payload | "$SCRIPT" >/dev/null 2>&1
EDGES="$SANDBOX/knowledge/graph/edges.jsonl"
[ -f "$EDGES" ] || fail "relations: edges.jsonl not created"
grep -q '"from":"wg-tunnel"' "$EDGES" || fail "relations: edge not appended"
grep -q '"source":"extractor"' "$EDGES" || fail "relations: source not stamped extractor"
grep -q '"type":"requires"' "$EDGES" || fail "relations: edge type wrong"
pass "extractor relations[] appended to edges.jsonl via merge-edges"
restore_path

# --- Test 2: Q&A-only transcript → predicate skips, PROJECT.md untouched.
init_sandbox "qna"
seed_transcript_qna_only
stub_claude_json '{"recent_decisions":["should-not-merge"],"open_blockers":[],"cross_refs":[],"files_touched":[]}'
PROJ="$SANDBOX/.second-brain/projects/test-slug/PROJECT.md"
ORIG_HASH=$(content_hash "$PROJ")
stop_payload | "$SCRIPT" >/dev/null 2>&1
NEW_HASH=$(content_hash "$PROJ")
[ "$ORIG_HASH" = "$NEW_HASH" ] || fail "qna: expected no merge but PROJECT.md changed"
pass "Q&A-only transcript: predicate skips extraction"
restore_path

# --- Test 3: claude unavailable + repeated session → [degraded] breadcrumb
# is recorded exactly ONCE per day, not per session. Locks in the
# dedup-per-day invariant in stop-extract.sh:157 ("Already recorded today —
# emit empty delta"). Without dedup, multi-session outages would push real
# decisions out of the 5-bullet cap.
init_sandbox "no-claude-dedup"
seed_transcript_with_edit
SAVED_PATH="$PATH"
export PATH=$(echo "$PATH" | tr ':' '\n' | while read -r d; do
  [ -x "$d/claude" ] || printf '%s:' "$d"
done | sed 's/:$//')
PROJ="$SANDBOX/.second-brain/projects/test-slug/PROJECT.md"
# Two consecutive runs in the same day with broken LLM. The second run uses a
# NEW session id: markers are session-keyed now (R1.2), so a fresh session gets
# a fresh window — the dedup-per-day invariant is what this test pins down.
stop_payload | "$SCRIPT" >/dev/null 2>&1
stop_payload "test-session-b" | "$SCRIPT" >/dev/null 2>&1
export PATH="$SAVED_PATH"
# SP-E: the breadcrumb now lives in a SIDECAR, dedup'd per day — NOT in PROJECT.md decisions.
PENDING="$SANDBOX/.second-brain/projects/test-slug/pending-extraction.log"
DEGRADED_COUNT=$(grep -c '\[degraded\] LLM extraction unavailable' "$PENDING" 2>/dev/null || echo 0)
[ "$DEGRADED_COUNT" -eq 1 ] || fail "no-claude-dedup: expected exactly 1 [degraded] sidecar line, got $DEGRADED_COUNT"
pass "claude unavailable: [degraded] breadcrumb dedup'd to once per day (in the sidecar)"
grep -qF '[degraded]' "$PROJ" 2>/dev/null && fail "SP-E: [degraded] leaked into PROJECT.md Recent decisions" || pass "SP-E: PROJECT.md decisions stay clean of [degraded]"

# --- Test 4: claude returns garbage → fail-soft, PROJECT.md untouched, exit 0.
init_sandbox "garbage"
seed_transcript_with_edit
stub_claude_garbage
PROJ="$SANDBOX/.second-brain/projects/test-slug/PROJECT.md"
ORIG_HASH=$(content_hash "$PROJ")
stop_payload | "$SCRIPT" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "garbage: expected exit 0 (fail-soft), got $rc"
pass "claude returns garbage: fail-soft, exit 0"
restore_path

# --- Test 5: missing transcript file → exit 0, no crash.
init_sandbox "missing-transcript"
stub_claude_json '{}'
PAYLOAD=$(jq -nc --arg tp "/nonexistent/transcript.jsonl" --arg cwd "$SANDBOX/repo/test-slug" \
  '{session_id:"x", transcript_path:$tp, cwd:$cwd, hook_event_name:"Stop"}')
echo "$PAYLOAD" | "$SCRIPT" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "missing-transcript: expected exit 0, got $rc"
pass "missing transcript: fail-soft, exit 0"
restore_path

# --- Test 6: malformed Stop payload on stdin → exit 0, no crash.
init_sandbox "bad-stdin"
echo "not json" | "$SCRIPT" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "bad-stdin: expected exit 0, got $rc"
pass "malformed Stop payload: fail-soft, exit 0"

# --- Test 7: degraded fallback strips scratch paths (/tmp, /var/tmp, /run).
# Forces extractor failure by stubbing claude to emit empty stdout, so the
# [degraded] breadcrumb writes. Project-relative paths should survive; scratch
# paths should be filtered out so they don't bloat the hot tier.
init_sandbox "scratch-filter"
seed_transcript_with_mixed_paths
cat > "$SANDBOX/path-stub/claude" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$SANDBOX/path-stub/claude"
export PATH="$SANDBOX/path-stub:$PATH"
stop_payload | "$SCRIPT" >/dev/null 2>&1
PROJ="$SANDBOX/.second-brain/projects/test-slug/PROJECT.md"
PENDING="$SANDBOX/.second-brain/projects/test-slug/pending-extraction.log"   # SP-E: breadcrumb lives here now
grep -q "src/foo.ts" "$PENDING" || fail "scratch-filter: project path should be retained in the sidecar breadcrumb"
grep -q "/tmp/" "$PENDING" && fail "scratch-filter: /tmp path leaked into the breadcrumb"
grep -q "/var/tmp/" "$PENDING" && fail "scratch-filter: /var/tmp path leaked into the breadcrumb"
grep -q "/run/" "$PENDING" && fail "scratch-filter: /run path leaked into the breadcrumb"
grep -qF '[degraded]' "$PROJ" 2>/dev/null && fail "SP-E: [degraded] leaked into PROJECT.md decisions" || true
pass "degraded fallback strips /tmp, /var/tmp, /run; keeps project paths (in sidecar, not decisions)"

# --- Test 7b (P1 Task 2): degraded fallback now writes a REAL deterministic delta to
# PROJECT.md — a grounded [auto-captured] files-changed decision — so capture is never a
# full no-op under the OAuth lock. (files_touched is informational/not merged, so the
# decision is the only path to PROJECT.md; it cites the files, staying signal not trash.)
init_sandbox "deterministic-delta"
seed_transcript_with_edit
cat > "$SANDBOX/path-stub/claude" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$SANDBOX/path-stub/claude"
export PATH="$SANDBOX/path-stub:$PATH"
stop_payload | "$SCRIPT" >/dev/null 2>&1
PROJ="$SANDBOX/.second-brain/projects/test-slug/PROJECT.md"
grep -q "auto-captured" "$PROJ" || fail "deterministic-delta: no [auto-captured] decision merged into PROJECT.md"
grep -q "src/foo.ts" "$PROJ" || fail "deterministic-delta: files-changed not reflected in PROJECT.md decision"
grep -qF '[degraded]' "$PROJ" 2>/dev/null && fail "SP-E: [degraded] leaked into PROJECT.md decisions" || true
pass "degraded fallback writes a real deterministic files-changed decision to PROJECT.md"
restore_path
restore_path

# --- Test 8 (R1.2): marker is session-keyed and ADVANCES — repeated Stops in
# one session archive each window exactly once, never re-archiving from 0.
init_sandbox "marker-advance"
seed_transcript_with_edit
stub_claude_json '{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[]}'
stop_payload | "$SCRIPT" >/dev/null 2>&1
MARKER="$SANDBOX/.second-brain/.last-extracted-line-test-slug--test-session"
[ -f "$MARKER" ] || fail "marker-advance: session-keyed marker file not created"
[ "$(cat "$MARKER")" = "3" ] || fail "marker-advance: marker should be 3 (TOTAL_LINES), got $(cat "$MARKER")"
ARCHIVE=$(ls "$SANDBOX/.second-brain/transcripts/"test-session_test-slug_*.txt 2>/dev/null | head -1)
[ -n "$ARCHIVE" ] || fail "marker-advance: archive not created"
C1=$(grep -c 'src/foo.ts' "$ARCHIVE")
# Second Stop, same session, transcript unchanged → no-new-lines gate; archive untouched.
stop_payload | "$SCRIPT" >/dev/null 2>&1
[ "$(grep -c 'src/foo.ts' "$ARCHIVE")" = "$C1" ] || fail "marker-advance: rerun re-archived the same window"
# New activity in the SAME session → only the new window is appended, once.
cat >> "$SANDBOX/transcript/session.jsonl" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/bar.ts","old_string":"a","new_string":"b"}}]}}
EOF
stop_payload | "$SCRIPT" >/dev/null 2>&1
[ "$(cat "$MARKER")" = "4" ] || fail "marker-advance: marker should advance to 4, got $(cat "$MARKER")"
[ "$(grep -c 'src/bar.ts' "$ARCHIVE")" = "1" ] || fail "marker-advance: new window not appended exactly once"
[ "$(grep -c 'src/foo.ts' "$ARCHIVE")" = "$C1" ] || fail "marker-advance: old window duplicated on append"
pass "session-keyed marker advances; each window archived exactly once"

# --- Test 8b (0.29.4): a final record with NO trailing newline must still be counted.
# `wc -l` counts newlines and undercounts a no-trailing-newline last line by one — and the
# Stop hook can read the transcript before the final line's newline is flushed. Pre-fix that
# dropped the final record (often the only tool_use) from the window AND advanced the marker
# past it, losing it permanently. awk NR counts records regardless of a missing final newline.
# printf '%s' (no \n) seeds the unflushed-last-line condition; the heredoc helpers can't.
printf '%s' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/NONL.ts","old_string":"a","new_string":"b"}}]}}' >> "$SANDBOX/transcript/session.jsonl"
stop_payload | "$SCRIPT" >/dev/null 2>&1
[ "$(cat "$MARKER")" = "5" ] || fail "no-trailing-newline: marker should reach 5 (awk NR), got $(cat "$MARKER") — wc -l undercount drops the final record"
[ "$(grep -c 'src/NONL.ts' "$ARCHIVE")" = "1" ] || fail "no-trailing-newline: final no-newline record not archived (dropped by wc -l undercount)"
pass "final record without a trailing newline is counted + archived (newline-safe record count)"
restore_path

# --- Test 9 (R1.2): two sessions in one project keep independent markers.
init_sandbox "marker-two-sessions"
seed_transcript_with_edit
stub_claude_json '{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[]}'
stop_payload "sess-a" | "$SCRIPT" >/dev/null 2>&1
stop_payload "sess-b" | "$SCRIPT" >/dev/null 2>&1
[ -f "$SANDBOX/.second-brain/.last-extracted-line-test-slug--sess-a" ] || fail "two-sessions: sess-a marker missing"
[ -f "$SANDBOX/.second-brain/.last-extracted-line-test-slug--sess-b" ] || fail "two-sessions: sess-b marker missing"
pass "independent per-session markers (no cross-session race)"
restore_path

# --- Test 10 (deep-review): a marker PAST the transcript end (shrink / unknown-
# key collision) must be clamped to 0, not gate extraction forever.
init_sandbox "marker-clamp"
seed_transcript_with_edit
stub_claude_json '{"recent_decisions":["use clamp semantics for stale extraction markers"],"open_blockers":[],"cross_refs":[],"files_touched":[]}'
echo "5000" > "$SANDBOX/.second-brain/.last-extracted-line-test-slug--test-session"
stop_payload | "$SCRIPT" >/dev/null 2>&1
PROJ="$SANDBOX/.second-brain/projects/test-slug/PROJECT.md"
grep -q "use clamp semantics for stale extraction markers" "$PROJ" || fail "marker-clamp: stale marker > EOF still gated extraction"
[ "$(cat "$SANDBOX/.second-brain/.last-extracted-line-test-slug--test-session")" = "3" ] \
  || fail "marker-clamp: marker not rewritten to TOTAL_LINES after clamp"
pass "stale marker past EOF clamped; extraction proceeds from 0"
restore_path

# --- Test 11 (deep-review): with a >500-line delta, the substantive gate and the
# archive must cover the FULL delta — a tool_use in the skipped middle must still
# trigger extraction, and the archive must contain the early content.
init_sandbox "window-full-delta"
{
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/early.ts","old_string":"a","new_string":"b"}}]}}'
  i=0; while [ $i -lt 520 ]; do printf '%s\n' '{"type":"user","message":{"role":"user","content":"filler"}}'; i=$((i+1)); done
} > "$SANDBOX/transcript/session.jsonl"
stub_claude_json '{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[]}'
stop_payload | "$SCRIPT" >/dev/null 2>&1
ARCHIVE=$(ls "$SANDBOX/.second-brain/transcripts/"test-session_test-slug_*.txt 2>/dev/null | head -1)
[ -n "$ARCHIVE" ] || fail "window-full-delta: tool_use outside the last 500 lines was gated out (no archive)"
grep -q 'src/early.ts' "$ARCHIVE" || fail "window-full-delta: early content missing from archive (middle dropped)"
pass "full delta gated+archived; LLM window cap applies to extractor input only"
restore_path

# --- Test 12 (D177): the EXIT trap installed later (for the extract temp
# files) must not REPLACE the gate-logging trap installed at the top of the
# script — bash keeps only the LAST trap for a given signal. Force a merge
# failure by pre-creating PROJECT.md as a DIRECTORY (merge-project-update.sh
# then exits non-zero: "project file not found"); assert (a) a `gate=merge-
# failed` row lands in the audit/error log and (b) the marker does NOT
# advance, so the same window is retried on the next Stop.
init_sandbox "merge-failed-trap"
seed_transcript_with_edit
stub_claude_json '{"recent_decisions":["should not reach PROJECT.md"],"open_blockers":[],"cross_refs":[],"files_touched":[]}'
PROJ="$SANDBOX/.second-brain/projects/test-slug/PROJECT.md"
rm -rf "$PROJ"
mkdir -p "$PROJ"   # PROJECT.md is now a DIRECTORY -> merge-project-update.sh must fail
MARKER="$SANDBOX/.second-brain/.last-extracted-line-test-slug--test-session"
rm -f "$MARKER"
stop_payload | "$SCRIPT" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "merge-failed-trap: expected exit 0 (fail-soft), got $rc"
( grep -q 'gate=merge-failed' "$SANDBOX/.second-brain/audit-log.jsonl" 2>/dev/null \
  || grep -q 'gate=merge-failed' "$SANDBOX/.second-brain/error-log.jsonl" 2>/dev/null ) \
  || fail "merge-failed-trap: no 'gate=merge-failed' row in audit-log or error-log — the second EXIT trap silenced the first"
[ ! -f "$MARKER" ] || fail "merge-failed-trap: marker advanced despite a failed merge — window would never be retried"
pass "D177: merge-failed is logged (chained trap) and the marker does not advance on a failed merge"
restore_path

# --- Test 13 (D077): SB_EXTRACT=off skips the LLM extraction call entirely
# (no `claude` spawn) but still archives the transcript window and advances
# the marker — a deterministic files-touched delta merges instead.
init_sandbox "extract-off"
seed_transcript_with_edit
# A claude stub that would fail the test if actually invoked.
cat > "$SANDBOX/path-stub/claude" <<'EOF'
#!/bin/bash
echo "CLAUDE WAS INVOKED — SB_EXTRACT=off must skip this" >&2
exit 1
EOF
chmod +x "$SANDBOX/path-stub/claude"
export PATH="$SANDBOX/path-stub:$PATH"
PROJ="$SANDBOX/.second-brain/projects/test-slug/PROJECT.md"
MARKER="$SANDBOX/.second-brain/.last-extracted-line-test-slug--test-session"
stop_payload | SB_EXTRACT=off "$SCRIPT" >/dev/null 2>&1
grep -q "CLAUDE WAS INVOKED" "$SANDBOX/.second-brain/error-log.jsonl" 2>/dev/null \
  && fail "extract-off: claude was invoked despite SB_EXTRACT=off"
grep -q "auto-captured" "$PROJ" || fail "extract-off: deterministic delta not merged into PROJECT.md"
[ -f "$MARKER" ] || fail "extract-off: marker not advanced"
ARCHIVE=$(ls "$SANDBOX/.second-brain/transcripts/"test-session_test-slug_*.txt 2>/dev/null | head -1)
[ -n "$ARCHIVE" ] || fail "extract-off: transcript window was not archived"
pass "D077: SB_EXTRACT=off skips the LLM call but still archives + advances the marker"
restore_path

# --- Test 14 (D179): the background episodic-index node process must not
# inherit stop-extract.sh's own stdout, and a non-zero exit must be logged
# loudly via sb_log_error (never silently swallowed by `2>/dev/null &`).
# Stub `node` to fail fast and deterministically — keeps this test fast and
# non-flaky regardless of the real indexer bundle's runtime.
init_sandbox "episodic-index-log"
seed_transcript_with_edit
stub_claude_json '{"recent_decisions":["episodic index log test"],"open_blockers":[],"cross_refs":[],"files_touched":[]}'
cat > "$SANDBOX/path-stub/node" <<'EOF'
#!/bin/bash
echo "stub node failure on stderr" >&2
echo "stub node failure on stdout"
exit 7
EOF
chmod +x "$SANDBOX/path-stub/node"
export PATH="$SANDBOX/path-stub:$PATH"
stop_payload | "$SCRIPT" >/dev/null 2>&1
# The backgrounded subshell races the parent's exit; poll briefly for its write.
for _i in $(seq 1 20); do
  grep -q 'episodic-index-cli exited' "$SANDBOX/.second-brain/error-log.jsonl" 2>/dev/null && break
  sleep 0.25
done
grep -q 'episodic-index-cli exited 7' "$SANDBOX/.second-brain/error-log.jsonl" 2>/dev/null \
  || fail "episodic-index-log: a non-zero episodic-index-cli exit was not logged via sb_log_error"
[ -f "$SANDBOX/.second-brain/episodic-index.log" ] \
  || fail "episodic-index-log: episodic-index.log was never created — stdout/stderr not redirected to a log file"
grep -q 'stub node failure on stdout' "$SANDBOX/.second-brain/episodic-index.log" \
  || fail "episodic-index-log: node's stdout was not captured in episodic-index.log (still inherits the hook's own stdout?)"
grep -q 'stub node failure on stderr' "$SANDBOX/.second-brain/episodic-index.log" \
  || fail "episodic-index-log: node's stderr was not captured in episodic-index.log"
pass "D179: background episodic-index process redirects stdout+stderr to a log and logs a non-zero exit"
restore_path

echo "ALL PASS"
