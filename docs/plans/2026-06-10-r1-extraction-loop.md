# R1 — Extraction Loop Stops Wasting Itself — Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Kill the three structural defects that make unattended extraction fail on this box — recursive hook self-spawns (all 169 `ec=124` timeouts), per-Stop marker resets (95%-duplicate archives), and uncapped/unfiltered extractor inputs — plus close the `episodic_read` path-guard gap (G-MCP-1).

**Architecture:** A `SB_NESTED_SPAWN=1` env circuit-breaker exported at the three headless `claude` spawn sites and honored by every capture/context hook (NEVER by the PreToolUse/PostToolUse security guards — an inheritable guard kill-switch would itself be a vulnerability). Extraction markers become session-keyed and monotonically advancing. The drainer gets a 120s timeout default, a too-small fast-path, an input byte-cap, and two GC sweeps. `episodic_read` gets the same `assertWithin` realpath guard the other MCP entry points received in v0.21.0.

**Tech Stack:** bash (scripts/, tests/), TypeScript + vitest (mcp/), jq. Spec: `docs/specs/2026-06-10-plugin-deep-dive-improvements-design.md` (wave R1). Evidence: `docs/specs/2026-06-10-plugin-deep-dive-findings-appendix.md` (HOOK-1..10, MCP-SEC-1).

**Versioning (release discipline):** one release: plugin `0.24.37 → 0.24.38`, marketplace.json lockstep, MCP server `2.6.7 → 2.6.8` (episodic_read schema description + behavior change → rebuild `mcp/dist`), one migration row, deep-review gate before merge.

**Executor caveats:**
- Tests run via `bash tests/<name>.sh` (no exec bit needed). When running inside a Claude Code session, `CLAUDECODE=1` leaks into the environment — new tests must `unset CLAUDECODE` (and `unset ANTHROPIC_API_KEY SB_EXTRACTOR_LOCAL_URL` where they source lib.sh) exactly as `tests/test-stop-extract.sh:13` does.
- The 4 pre-existing mode-only diffs on `tests/*.sh` are an unrelated known chore (R6) — leave them out of your commits (`git add` specific paths, never `git add -A`).

---

## File structure

| File | Action | Responsibility |
|---|---|---|
| `tests/test-nested-spawn-guard.sh` | Create | R1.1 contract: static guard presence, security-guard exclusion, runtime no-op, spawn-site env+cwd, timeout default |
| 13 hook scripts in `scripts/` (list in Task 2) | Modify (2 lines each) | early-exit under `SB_NESTED_SPAWN=1` |
| `scripts/lib.sh` | Modify | spawn-site env+scratch cwd (`sb_call_extractor`), marker-key helper, drainer timeout 120s, input cap |
| `scripts/maintain-llm-drain.sh` | Modify (1 line) | guard env on the bwrap'd claude spawn |
| `scripts/stop-extract.sh` | Modify | session-keyed advancing marker (no more per-Stop clear) |
| `scripts/pre-compact.sh` | Modify | same marker key; inner timeout 40s→30s |
| `scripts/extract-drain.sh` | Modify | too-small fast-path; marker GC; scratch-transcript GC |
| `scripts/subagent-capture.sh` | Modify | skip workflow "holding-message" stubs |
| `skills/review/SKILL.md` | Modify (1 line) | staleness check matches session-keyed marker glob |
| `tests/test-stop-extract.sh` | Modify | marker-semantics update + 2 new tests |
| `tests/test-extract-drain.sh` | Modify | `SB_DRAIN_MIN_BYTES=0` for legacy cases + 2 new test groups |
| `tests/test-subagent-capture.sh` | Modify | holding-stub skip + regression case |
| `tests/test-lib-extract-budget.sh` | Create | input byte-cap keeps newest tail |
| `mcp/src/tools/episodic-search.ts` | Modify | export `assertTranscriptPath` |
| `mcp/src/tools/episodic-read-guard.test.ts` | Create | traversal/symlink/NUL rejection |
| `mcp/src/server.ts` | Modify | guard wiring, tool description, version 2.6.8 |
| `mcp/dist/*` | Rebuild | `npm run bundle` (dist is git-tracked) |
| `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `skills/upgrade/SKILL.md` | Modify | 0.24.38 + migration row |

---

### Task 1: Branch + commit the design artifacts

- [ ] **Step 1: Create the release branch from main**

```bash
git checkout main && git pull
git checkout -b fix/0.24.38-r1-extraction-loop
```

- [ ] **Step 2: Commit the spec, appendix, and this plan**

```bash
git add docs/specs/2026-06-10-plugin-deep-dive-improvements-design.md \
        docs/specs/2026-06-10-plugin-deep-dive-findings-appendix.md \
        docs/plans/2026-06-10-r1-extraction-loop.md
git commit -m "design+plan: R1 extraction-loop fixes (deep-dive wave 1)"
```

---

### Task 2: Nested-spawn circuit breaker — hooks honor `SB_NESTED_SPAWN=1`

**Why:** the drainer's headless `claude -p` children load the full plugin hook stack (~24s on the Pi vs a 25s timeout — every observed `ec=124`). The guard makes capture/context hooks no-op inside plugin-spawned sessions. Security guards are deliberately excluded.

**Files:**
- Create: `tests/test-nested-spawn-guard.sh`
- Modify: `scripts/ensure-dirs.sh`, `scripts/discover-tools.sh`, `scripts/discover-installed.sh`, `scripts/discover-doc-sources.sh`, `scripts/session-load.sh`, `scripts/dream-autostage.sh`, `scripts/persona-context.sh`, `scripts/stop-verify-gate.sh`, `scripts/stop-extract.sh`, `scripts/sar-summary.sh`, `scripts/cost-router-capture.sh`, `scripts/pre-compact.sh`, `scripts/subagent-capture.sh`

- [ ] **Step 1: Write the failing test** — create `tests/test-nested-spawn-guard.sh`:

```bash
#!/bin/bash
# tests/test-nested-spawn-guard.sh — R1.1 nested-spawn circuit breaker.
# Headless `claude -p` children spawned by the drainer/maintainer inherit
# SB_NESTED_SPAWN=1; every capture/context hook must then no-op instantly
# (exit 0, no output, no writes) instead of re-running the full plugin stack
# (~24s on a Pi — the cause of every observed ec=124 extraction timeout).
# SECURITY guards (PreToolUse/PostToolUse/ConfigChange) must NOT honor the
# env: an inheritable kill-switch on guards would itself be a vulnerability.
set -u
REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

GUARDED="ensure-dirs.sh discover-tools.sh discover-installed.sh discover-doc-sources.sh session-load.sh dream-autostage.sh persona-context.sh stop-verify-gate.sh stop-extract.sh sar-summary.sh cost-router-capture.sh pre-compact.sh subagent-capture.sh"
SECURITY="persona-tool-guard.sh wiki-write-guard.sh symlink-guard.sh flow-guard.sh config-change-guard.sh quality-gate.sh tool-return-scanner.sh simplicity-gate.sh"

# --- Part A: static — every capture/context hook carries the guard line.
for s in $GUARDED; do
  grep -q 'SB_NESTED_SPAWN:-0' "$REPO_ROOT/scripts/$s" \
    || fail "static: scripts/$s lacks the nested-spawn guard"
done
pass "static: all capture/context hook scripts carry the guard"

# --- Part B: static — security guards must NOT be disableable via the env.
for s in $SECURITY; do
  grep -q 'SB_NESTED_SPAWN' "$REPO_ROOT/scripts/$s" \
    && fail "static: scripts/$s (security guard) must not honor SB_NESTED_SPAWN"
done
pass "static: no security guard honors SB_NESTED_SPAWN"

# --- Part C: runtime — guarded scripts exit 0 with no output and no writes.
SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
export BRAIN_DIR="$SANDBOX/brain"; mkdir -p "$BRAIN_DIR"
export SB_NESTED_SPAWN=1
for s in $GUARDED; do
  OUT=$(echo '{"session_id":"x","transcript_path":"/nonexistent","cwd":"'"$SANDBOX"'"}' \
        | bash "$REPO_ROOT/scripts/$s" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || fail "runtime: $s exited $rc under SB_NESTED_SPAWN=1"
  [ -z "$OUT" ] || fail "runtime: $s emitted output under SB_NESTED_SPAWN=1: $(printf '%s' "$OUT" | head -c 80)"
done
LEFT=$(find "$BRAIN_DIR" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
[ "$LEFT" = "0" ] || fail "runtime: guarded hooks wrote $LEFT path(s) into BRAIN_DIR"
unset SB_NESTED_SPAWN
pass "runtime: all guarded hooks no-op under SB_NESTED_SPAWN=1"

# --- Part D: spawn site exports the env and runs in the scratch cwd (Task 3;
# RED until Task 3 lands — that is expected while executing Task 2).
unset CLAUDECODE 2>/dev/null || true
unset ANTHROPIC_API_KEY 2>/dev/null || true
unset SB_EXTRACTOR_LOCAL_URL 2>/dev/null || true
export PROBE="$SANDBOX/probe"
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/claude" <<'EOF'
#!/bin/bash
printf '%s %s\n' "${SB_NESTED_SPAWN:-unset}" "$PWD" > "$PROBE"
echo '{"ok":true}'
EOF
chmod +x "$SANDBOX/bin/claude"
export PATH="$SANDBOX/bin:$PATH"
IN=$(mktemp); OUTF=$(mktemp); echo data > "$IN"
( source "$REPO_ROOT/scripts/lib.sh"
  sb_call_extractor "$IN" "$OUTF" test-model test-prompt 5 >/dev/null 2>&1 )
[ -f "$PROBE" ] || fail "spawn: claude stub never invoked"
read -r ENVV CWDV < "$PROBE"
[ "$ENVV" = "1" ] || fail "spawn: SB_NESTED_SPAWN not set on extractor spawn (got $ENVV)"
[ "$CWDV" = "$BRAIN_DIR/scratch" ] || fail "spawn: extractor cwd is $CWDV, want $BRAIN_DIR/scratch"
rm -f "$IN" "$OUTF"
pass "spawn site exports SB_NESTED_SPAWN=1 and runs in BRAIN_DIR/scratch"

# --- Part E: static — maintainer spawn guarded; drainer timeout default 120s.
grep -q 'SB_NESTED_SPAWN=1' "$REPO_ROOT/scripts/maintain-llm-drain.sh" \
  || fail "static: maintain-llm-drain.sh claude spawn lacks SB_NESTED_SPAWN=1"
grep -q 'SB_EXTRACT_TIMEOUT:-120' "$REPO_ROOT/scripts/lib.sh" \
  || fail "static: sb_extract_transcript drainer timeout default is not 120s"
pass "static: maintainer spawn guarded; drainer timeout default 120s"

echo "ALL PASS"
```

- [ ] **Step 2: Run it — expect FAIL at Part A**

Run: `bash tests/test-nested-spawn-guard.sh`
Expected: `FAIL: static: scripts/ensure-dirs.sh lacks the nested-spawn guard`

- [ ] **Step 3: Add the guard to all 13 scripts**

In each of the 13 `GUARDED` scripts, insert these two lines immediately **after** the `set -u` (or `set -euo pipefail`) line; if a script has no `set` line, insert as the first executable line after the shebang/comment header. Critically: in `stop-extract.sh`, `pre-compact.sh`, and `subagent-capture.sh` this lands **above** the `source .../lib.sh` line, so a nested session pays nothing at all.

```bash
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0
```

- [ ] **Step 4: Run the test — Parts A, B, C pass; Part D still RED**

Run: `bash tests/test-nested-spawn-guard.sh`
Expected: `PASS` for Parts A–C, then `FAIL: spawn: claude stub never invoked` *or* `SB_NESTED_SPAWN not set` (Part D is Task 3's contract).

- [ ] **Step 5: Run the neighbors that exercise these scripts**

Run: `bash tests/test-stop-extract.sh && bash tests/test-subagent-capture.sh`
Expected: `ALL PASS` for both (the guard is inert when the env is unset).

- [ ] **Step 6: Commit**

```bash
git add tests/test-nested-spawn-guard.sh scripts/ensure-dirs.sh scripts/discover-tools.sh \
        scripts/discover-installed.sh scripts/discover-doc-sources.sh scripts/session-load.sh \
        scripts/dream-autostage.sh scripts/persona-context.sh scripts/stop-verify-gate.sh \
        scripts/stop-extract.sh scripts/sar-summary.sh scripts/cost-router-capture.sh \
        scripts/pre-compact.sh scripts/subagent-capture.sh
git commit -m "feat(hooks): SB_NESTED_SPAWN circuit breaker on capture/context hooks (R1.1, HOOK-3)"
```

---

### Task 3: Spawn sites — export the guard env, scratch cwd, 120s drainer timeout

**Files:**
- Modify: `scripts/lib.sh` (`sb_call_extractor` ~771-957; `sb_extract_transcript` line 1087)
- Modify: `scripts/maintain-llm-drain.sh` (line 104)
- Test: `tests/test-nested-spawn-guard.sh` Parts D+E (already written, currently RED)

- [ ] **Step 1: Confirm Parts D+E are RED**

Run: `bash tests/test-nested-spawn-guard.sh`
Expected: fails at Part D or E.

- [ ] **Step 2: `sb_call_extractor` — scratch dir + env on all three claude invocations**

In `scripts/lib.sh`, inside `sb_call_extractor` right after `caller_script="${SB_SCRIPT_NAME:-${0##*/}}"` (line ~775), add:

```bash
  # R1.1 nested-spawn containment: the headless child (a) inherits
  # SB_NESTED_SPAWN=1 so plugin hooks no-op inside it instead of re-running the
  # full SessionStart/Stop stack (~24s on a Pi — the cause of every ec=124
  # timeout), and (b) runs with cwd in a dedicated scratch dir so its junk
  # transcript lands in ONE prunable ~/.claude/projects entry.
  local scratch_dir="$BRAIN_DIR/scratch"
  mkdir -p "$scratch_dir" 2>/dev/null || scratch_dir="$PWD"
```

Replace the direct invocation block (current lines 860-868):

```bash
    if [ -n "$TBIN" ]; then
      ( cd "$scratch_dir" && SB_NESTED_SPAWN=1 "$TBIN" "$timeout_s" "${WRAP_PREFIX[@]}" claude "${CLI_ARGS[@]}" \
        < "$input_file" > "$out_file" 2>"$err_file" )
      claude_ec=$?
    else
      ( cd "$scratch_dir" && SB_NESTED_SPAWN=1 "${WRAP_PREFIX[@]}" claude "${CLI_ARGS[@]}" \
        < "$input_file" > "$out_file" 2>"$err_file" )
      claude_ec=$?
    fi
```

Replace the pty-retry `script(1)` invocation (current line 920):

```bash
        ( cd "$scratch_dir" && SB_NESTED_SPAWN=1 script -qfc "bash -c $(printf '%q' "$inner")" /dev/null > "$pty_raw" 2>/dev/null </dev/null ) || true
```

(Env-assignment prefixes propagate through `timeout`/`script`/`bash -c` to the `claude` child; the `( cd … )` subshell keeps the hook's own cwd untouched, and `$?` after a subshell is the subshell's exit code, so `claude_ec` capture is unchanged.)

- [ ] **Step 3: drainer timeout default** — `scripts/lib.sh` line 1087 (inside `sb_extract_transcript`, which only the out-of-band drainer calls — the in-hook paths in stop-extract/pre-compact keep their own 25s/30s defaults):

```bash
  local timeout_s="${SB_EXTRACT_TIMEOUT:-120}"   # drainer runs out-of-band (no hook budget); 25s lost to ~24s plugin self-load pre-R1
```

- [ ] **Step 4: maintainer spawn** — `scripts/maintain-llm-drain.sh` line 104, prefix the env:

```bash
SB_NESTED_SPAWN=1 ${TBIN:+$TBIN "$TO"} bwrap "${BWRAP_ARGS[@]}" \
  -- claude -p --permission-mode bypassPermissions --model "$MODEL" "$PROMPT" >/dev/null 2>&1 || rc=$?
```

- [ ] **Step 5: Run the guard test — fully GREEN now**

Run: `bash tests/test-nested-spawn-guard.sh`
Expected: `ALL PASS`

- [ ] **Step 6: Run the extractor-backend + drain neighbors**

Run: `bash tests/test-lib-extractor-backend.sh && bash tests/test-extract-drain.sh && bash tests/test-stop-extract.sh`
Expected: `ALL PASS` each. If `test-lib-extractor-backend.sh` asserts on cwd or env of its stubs, update those assertions to accept the new `scratch` cwd — the contract change is deliberate.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib.sh scripts/maintain-llm-drain.sh tests/test-nested-spawn-guard.sh tests/test-lib-extractor-backend.sh
git commit -m "feat(extract): spawn sites export SB_NESTED_SPAWN + scratch cwd; drainer timeout 120s (R1.1, HOOK-2)"
```

---

### Task 4: Session-keyed, advancing extraction markers (+ PreCompact budget align)

**Why:** `stop-extract.sh` clears the slug-keyed marker on every Stop, so each firing re-archives the last-500-line window — one real session produced a 2.9MB archive containing 18 copies of the same window (HOOK-1). Session-keying also removes the two-sessions-one-project race. While editing pre-compact.sh: its 40s inner timeout vs 45s hook budget leaves a 5s kill-window (HOOK-10) — drop to 30s.

**Files:**
- Modify: `scripts/lib.sh` (marker helpers ~326-350), `scripts/stop-extract.sh` (50-51, 92-122, 243, 253), `scripts/pre-compact.sh` (7, 28, 38-41, 56, 77, 184, 194), `skills/review/SKILL.md` (line 34)
- Test: `tests/test-stop-extract.sh`

- [ ] **Step 1: Update `tests/test-stop-extract.sh` — make `stop_payload` session-parametric**

Replace the `stop_payload()` function (lines 111-116) with:

```bash
stop_payload() {
  jq -nc --arg sid "${1:-test-session}" \
        --arg tp "$SANDBOX/transcript/session.jsonl" \
        --arg cwd "$SANDBOX/repo/test-slug" \
        '{session_id:$sid, transcript_path:$tp, cwd:$cwd, hook_event_name:"Stop"}'
}
```

In **Test 3** (`no-claude-dedup`), the second run currently relies on the old clear-marker behavior. Replace lines 175-178:

```bash
# Two consecutive runs in the same day with broken LLM. The second run uses a
# NEW session id: markers are session-keyed now (R1.2), so a fresh session gets
# a fresh window — the dedup-per-day invariant is what this test pins down.
stop_payload | "$SCRIPT" >/dev/null 2>&1
stop_payload "test-session-b" | "$SCRIPT" >/dev/null 2>&1
```

(delete the intervening `seed_transcript_with_edit` re-seed and its stale comment.)

- [ ] **Step 2: Append two new tests before the final `echo "ALL PASS"`**

```bash
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
```

- [ ] **Step 3: Run — expect FAIL**

Run: `bash tests/test-stop-extract.sh`
Expected: `FAIL: marker-advance: session-keyed marker file not created`

- [ ] **Step 4: lib.sh — add the key helper and fix the stale comment**

Replace the comment block at lines 326-328 and add the helper after `sb_clear_extraction_marker` (line 350):

```bash
# --- Extraction marker helpers ---
# Track which transcript lines have been extracted. Keys are SESSION-scoped
# (slug--session_id, R1.2): pre-compact and stop process disjoint windows of
# one session, repeated Stop firings resume where the last finished (instead
# of re-archiving from line 0 — the 18x-duplicate-archive bug), and two
# concurrent sessions in one project cannot race each other's marker.
# Stale markers are swept by extract-drain.sh after 7 days.
```

```bash
# Compose the extraction-marker key for a (slug, session) pair. The session id
# is sanitized for filename safety (it comes from the hook payload).
sb_extraction_marker_key() {
  local slug="$1" sid
  sid=$(printf '%s' "${2:-unknown}" | tr -cd 'A-Za-z0-9._-')
  [ -n "$sid" ] || sid="unknown"
  printf '%s--%s' "$slug" "$sid"
}
```

- [ ] **Step 5: stop-extract.sh — key by session, advance instead of clear**

(a) After the `CWD=` line (line 51), add:

```bash
SESSION_ID=$(echo "$RAW" | jq -r '.session_id // "unknown"' 2>/dev/null | tr -d '\r')
```

(b) After the SLUG empty-check (line 60), add:

```bash
MARKER_KEY=$(sb_extraction_marker_key "$SLUG" "$SESSION_ID")
```

(c) Line 92: `LAST_LINE=$(sb_get_extraction_marker "$MARKER_KEY")`

(d) Lines 96-100 (no-new-lines gate) — drop the clear:

```bash
if [ "$NEW_LINES" -lt 1 ]; then
  log_gate "no-new-lines marker=$LAST_LINE total=$TOTAL_LINES"
  exit 0
fi
```

(e) Lines 116-122 (tool-count-zero gate) — advance past the examined window instead of clearing (stops the per-turn re-examination churn):

```bash
if [ "${TOOL_COUNT:-0}" -lt 1 ]; then
  TS_LINES=$NEW_LINES
  TS_FIRST_TYPE=$(sed -n "${START_LINE}p" "$TRANSCRIPT" 2>/dev/null | jq -r '.type // "no-type"' 2>/dev/null | tr -d '\n')
  log_gate "tool-count-zero lines=$TS_LINES first-type=$TS_FIRST_TYPE marker=$LAST_LINE"
  sb_set_extraction_marker "$MARKER_KEY" "$TOTAL_LINES"
  exit 0
fi
```

(f) Line 243: delete the now-duplicate `SESSION_ID=` read (keep the `sb_archive_transcript` call using `$SESSION_ID`).

(g) Line 253: replace `sb_clear_extraction_marker "$SLUG"` with:

```bash
sb_set_extraction_marker "$MARKER_KEY" "$TOTAL_LINES"
```

- [ ] **Step 6: pre-compact.sh — same key + timeout align**

(a) Line 7 comment: `# (.last-extracted-line-<slug>--<session_id>) so each processes a disjoint window.`
(b) Line 28: `EXTRACT_TIMEOUT="${SB_EXTRACT_TIMEOUT:-30}"` — keeps ≥15s headroom inside the 45s hooks.json budget (HOOK-10).
(c) After the `CWD=` line (line 39): add the same `SESSION_ID=$(…)` line as stop-extract Step 5a.
(d) After the slug empty-check (line 48): `MARKER_KEY=$(sb_extraction_marker_key "$SLUG" "$SESSION_ID")`
(e) Line 56: `LAST_LINE=$(sb_get_extraction_marker "$MARKER_KEY")`
(f) Line 77: `sb_set_extraction_marker "$MARKER_KEY" "$TOTAL_LINES"`
(g) Line 184: delete the duplicate `SESSION_ID=` read.
(h) Line 194: `sb_set_extraction_marker "$MARKER_KEY" "$TOTAL_LINES"`

- [ ] **Step 7: skills/review/SKILL.md line 34 — staleness glob**

Replace the marker reference with:

```
A project is stale if its last extraction (newest mtime among `~/.second-brain/.last-extracted-line-<slug>--*`) or PROJECT.md mtime is older than 14 days. Surface them so the user knows what's drifted.
```

- [ ] **Step 8: Run to GREEN**

Run: `bash tests/test-stop-extract.sh`
Expected: `ALL PASS` (all 9 tests).

- [ ] **Step 9: Commit**

```bash
git add scripts/lib.sh scripts/stop-extract.sh scripts/pre-compact.sh skills/review/SKILL.md tests/test-stop-extract.sh
git commit -m "fix(extract): session-keyed advancing markers — end per-Stop re-archiving (R1.2, HOOK-1/HOOK-10)"
```

---

### Task 5: Drainer GC sweeps — stale markers + scratch transcripts

**Files:**
- Modify: `scripts/extract-drain.sh` (after the batch loop, before the health write at line ~140)
- Test: `tests/test-extract-drain.sh`

- [ ] **Step 1: Write the failing test** — append to `tests/test-extract-drain.sh` (place LAST in the file; it re-exports HOME):

```bash
echo "Test: GC sweeps — stale markers + scratch transcripts"
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
```

(`touch -t YYYYMMDDhhmm` is POSIX — works on GNU and BSD/macOS, matching the portability discipline.)

- [ ] **Step 2: Run — expect the new lines to FAIL**

Run: `bash tests/test-extract-drain.sh`
Expected: `FAIL: stale marker survived` (and scratch lines).

- [ ] **Step 3: Implement** — in `scripts/extract-drain.sh`, after the batch `done < <(ls …)` (line 133) and before the `DRAIN_BACKEND=` health block:

```bash
# --- GC sweeps (R1.2) ---
# Session-keyed extraction markers accumulate one file per session; sweep those
# untouched for 7+ days (their sessions are long over). Also sweeps legacy
# slug-keyed markers from pre-0.24.38.
find "$BRAIN_DIR" -maxdepth 1 -name '.last-extracted-line-*' -mtime +7 -delete 2>/dev/null || true
# Transcripts of our own nested extractor spawns (cwd = BRAIN_DIR/scratch →
# they all land in one ~/.claude/projects entry). Pure junk byproducts.
for pd in "$HOME"/.claude/projects/*second-brain-scratch*; do
  [ -d "$pd" ] && find "$pd" -name '*.jsonl' -mtime +3 -delete 2>/dev/null
done
```

- [ ] **Step 4: Run to GREEN**

Run: `bash tests/test-extract-drain.sh`
Expected: all lines `PASS`, summary green.

- [ ] **Step 5: Commit**

```bash
git add scripts/extract-drain.sh tests/test-extract-drain.sh
git commit -m "feat(drain): GC stale extraction markers (7d) + nested-spawn scratch transcripts (3d) (R1.2)"
```

---

### Task 6: Extractor input byte-cap (newest tail wins)

**Files:**
- Create: `tests/test-lib-extract-budget.sh`
- Modify: `scripts/lib.sh` line 1126 (inside `sb_extract_transcript`)

- [ ] **Step 1: Write the failing test** — create `tests/test-lib-extract-budget.sh`:

```bash
#!/bin/bash
# tests/test-lib-extract-budget.sh — R1.2 input cap: sb_extract_transcript must
# feed the extractor at most SB_EXTRACT_MAX_BYTES of archive body, keeping the
# NEWEST exchanges (tail). Uncapped multi-MB archives could never finish before
# the timeout and burned full retry cycles toward quarantine (HOOK-4).
set -u
unset CLAUDECODE 2>/dev/null || true
unset ANTHROPIC_API_KEY 2>/dev/null || true
unset SB_EXTRACTOR_LOCAL_URL 2>/dev/null || true
REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"
export BRAIN_DIR="$SANDBOX/brain"; mkdir -p "$BRAIN_DIR/transcripts"
fail() { echo "FAIL: $1"; exit 1; }

export PROBE_IN="$SANDBOX/stdin-capture"
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/claude" <<'EOF'
#!/bin/bash
cat > "$PROBE_IN"
echo '{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[]}'
EOF
chmod +x "$SANDBOX/bin/claude"
export PATH="$SANDBOX/bin:$PATH"

# 300KB body: HEAD-SENTINEL early, TAIL-SENTINEL at the end.
TX="$BRAIN_DIR/transcripts/big_proj_2026-06-10.txt"
{
  printf -- '--- session-meta ---\nsession_id: big\nproject_slug: proj\ndate: 2026-06-10\ntool_count: 5\nline_count: 9\n---\n\n'
  echo "HEAD-SENTINEL"
  i=0; while [ $i -lt 3000 ]; do printf 'ASSISTANT:\n  [Edit] src/file%05d.ts — padding line of roughly one hundred bytes to inflate the archive body\n' "$i"; i=$((i+1)); done
  echo "TAIL-SENTINEL"
} > "$TX"

( source "$REPO_ROOT/scripts/lib.sh"
  sb_extract_transcript "$TX" proj >/dev/null 2>&1 )

[ -f "$PROBE_IN" ] || fail "extractor never invoked"
BYTES=$(wc -c < "$PROBE_IN" | tr -d ' ')
# stdin = PROJECT.md scaffold + separator + capped body (200000) — generous slack:
[ "$BYTES" -lt 230000 ] || fail "extractor stdin is $BYTES bytes — cap not applied"
grep -q 'TAIL-SENTINEL' "$PROBE_IN" || fail "newest content (tail) missing from capped input"
grep -q 'HEAD-SENTINEL' "$PROBE_IN" && fail "oldest content survived the cap (should be tail-capped)"
echo "PASS: extractor input capped to newest ~200KB"
echo "ALL PASS"
```

- [ ] **Step 2: Run — expect FAIL**

Run: `bash tests/test-lib-extract-budget.sh`
Expected: `FAIL: extractor stdin is 3xxxxx bytes — cap not applied`

- [ ] **Step 3: Implement** — `scripts/lib.sh` line 1126, replace:

```bash
    sed '1,/^---$/d' "$txt"   # drop the meta header, keep the body
```

with:

```bash
    # Body only, tail-capped: keep the NEWEST exchanges. An uncapped multi-MB
    # archive can never finish before the timeout on a Pi (R1.2, HOOK-4).
    sed '1,/^---$/d' "$txt" | tail -c "${SB_EXTRACT_MAX_BYTES:-200000}"
```

- [ ] **Step 4: Run to GREEN, plus neighbors**

Run: `bash tests/test-lib-extract-budget.sh && bash tests/test-extract-drain.sh`
Expected: `ALL PASS` both.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh tests/test-lib-extract-budget.sh
git commit -m "feat(extract): cap drainer extractor input at 200KB, newest-tail (R1.2, HOOK-4)"
```

---

### Task 7: Drainer too-small fast-path (no LLM spawn for stub archives)

**Why:** 50 pending 378-byte subagent stubs each cost up to 2 spawns × 3 retries. Tiny bodies have nothing to extract; they stay on disk for episodic search (the capture goal) — only the LLM call is skipped.

**Files:**
- Modify: `scripts/extract-drain.sh` (pre-pass before the batch loop), `tests/test-extract-drain.sh`

- [ ] **Step 1: Protect the existing fixtures** — `tests/test-extract-drain.sh` uses tiny `mk_tx` bodies that must keep exercising the stub. Near the top, after `export SB_INTERACTIVE_OVERRIDE=inactive`, add:

```bash
# R1.2: the too-small fast-path would skip these deliberately tiny fixtures —
# disable it for the legacy cases; the fast-path test re-enables it per-call.
export SB_DRAIN_MIN_BYTES=0
```

- [ ] **Step 2: Write the failing test** — append to `tests/test-extract-drain.sh` (BEFORE the Task-5 GC test, which must stay last):

```bash
echo "Test: too-small fast-path marks done without an LLM spawn"
rm -f "$STATE"; rm -f "$BRAIN_DIR/transcripts"/*.txt 2>/dev/null || true
CALLED="$SANDBOX/called"; rm -f "$CALLED"
cat > "$STUB" <<EOF2
#!/bin/bash
touch "$CALLED"
exit 0
EOF2
chmod +x "$STUB"
mk_tx tiny1_x.txt someproj     # mk_tx bodies are well under 1KB
SB_DRAIN_MIN_BYTES=1024 bash "$DRAIN" >/dev/null 2>&1 || true
grep -q '"basename":"tiny1_x.txt"' "$STATE" && grep -q '"reason":"too-small"' "$STATE" \
  && ok "too-small archive marked ok/too-small in state" || no "too-small not recorded in state"
[ ! -f "$CALLED" ] && ok "extractor NOT spawned for too-small archive" || no "extractor was spawned for a too-small archive"
# Idempotent: second run must skip it via sb_extraction_done.
SB_DRAIN_MIN_BYTES=1024 bash "$DRAIN" >/dev/null 2>&1 || true
eq "too-small recorded exactly once" "$(grep -c '"basename":"tiny1_x.txt"' "$STATE")" "1"
```

- [ ] **Step 3: Run — expect FAIL**

Run: `bash tests/test-extract-drain.sh`
Expected: `FAIL: too-small not recorded in state`

- [ ] **Step 4: Implement** — in `scripts/extract-drain.sh`, after the `now()` definition (line 108) and before `processed=0`:

```bash
# --- Too-small fast-path (R1.2, HOOK-5) ---
# Archives whose post-header body is tiny (e.g. 378-byte workflow-subagent
# stubs) have nothing extractable: mark them done WITHOUT an LLM spawn. They
# stay on disk for episodic search — only extraction is skipped. Runs before
# the batch loop so stubs never consume batch slots.
MIN_BODY="${SB_DRAIN_MIN_BYTES:-1024}"
case "$MIN_BODY" in ''|*[!0-9]*) MIN_BODY=1024 ;; esac
if [ "$MIN_BODY" -gt 0 ]; then
  while IFS= read -r tf; do
    [ -n "$tf" ] || continue
    base=$(basename "$tf")
    sb_extraction_done "$base" "$STATE" && continue
    body_bytes=$(sed '1,/^---$/d' "$tf" 2>/dev/null | wc -c | tr -d ' ')
    if [ "${body_bytes:-0}" -lt "$MIN_BODY" ]; then
      printf '{"basename":%s,"ts":"%s","outcome":"ok","reason":"too-small"}\n' \
        "$(jq -Rn --arg b "$base" '$b')" "$(now)" >> "$STATE"
    fi
  done < <(ls -1tr "$TX_DIR"/*.txt 2>/dev/null)
fi
```

- [ ] **Step 5: Run to GREEN**

Run: `bash tests/test-extract-drain.sh`
Expected: all `PASS` including the legacy cases (they run with `SB_DRAIN_MIN_BYTES=0`).

- [ ] **Step 6: Commit**

```bash
git add scripts/extract-drain.sh tests/test-extract-drain.sh
git commit -m "feat(drain): too-small fast-path — no LLM spawn for sub-1KB archive bodies (R1.2, HOOK-5)"
```

---

### Task 8: subagent-capture skips workflow "holding-message" stubs

**Why:** workflow subagents return their real answer via a StructuredOutput tool call; their last *text* block is an interim "Holding here until…" message. 50 such 378-byte stubs were archived from one fan-out (HOOK-5).

**Files:**
- Modify: `scripts/subagent-capture.sh` (insert after the tool-count gate at line 52; move the `MIN` definition up), `tests/test-subagent-capture.sh`

- [ ] **Step 1: Write the failing tests** — append to `tests/test-subagent-capture.sh`, following its existing fixture style (build a transcript file, build the hook payload with a non-self `agent_type`, run the script, assert on `$BRAIN_DIR/transcripts/sub-*.txt`). Two cases:

```bash
# --- Test (R1.2): final assistant record is tool_use-only and the last text is
# an interim holding message → must NOT archive.
TX="$SANDBOX/holding.jsonl"
cat > "$TX" <<'EOF'
{"type":"user","message":{"role":"user","content":"task"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Holding here until the review returns; this filler comfortably exceeds the eighty-character minimum so the pre-R1 gate would have archived it as a result."}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"StructuredOutput","input":{"result":"the real answer went through the tool call"}},{"type":"tool_use","name":"Grep","input":{"pattern":"x"}}]}}
EOF
BEFORE=$(ls "$BRAIN_DIR/transcripts"/sub-*.txt 2>/dev/null | wc -l | tr -d ' ')
jq -nc --arg tp "$TX" --arg cwd "$PWD" \
  '{transcript_path:$tp, agent_type:"worker", agent_id:"hold1", session_id:"s", cwd:$cwd}' \
  | bash "$SCRIPT" >/dev/null 2>&1
AFTER=$(ls "$BRAIN_DIR/transcripts"/sub-*.txt 2>/dev/null | wc -l | tr -d ' ')
[ "$BEFORE" = "$AFTER" ] && pass "holding-message stub NOT archived" || fail "holding-message stub was archived"

# --- Regression: a final text-only record (a real prose result) still archives.
TX2="$SANDBOX/real.jsonl"
cat > "$TX2" <<'EOF'
{"type":"user","message":{"role":"user","content":"task"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Grep","input":{"pattern":"x"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Final prose result with plenty of substance: the refactor touched three modules and every call site now uses the new session-keyed marker helper introduced in R1."}]}}
EOF
jq -nc --arg tp "$TX2" --arg cwd "$PWD" \
  '{transcript_path:$tp, agent_type:"worker", agent_id:"real1", session_id:"s", cwd:$cwd}' \
  | bash "$SCRIPT" >/dev/null 2>&1
ls "$BRAIN_DIR/transcripts"/sub-real1_*.txt >/dev/null 2>&1 \
  && pass "final text result still archived" || fail "real final result no longer archived"
```

Adapt variable names (`$SCRIPT`, `$BRAIN_DIR`, `pass`/`fail` vs `ok`/`no`) to the file's existing helpers when appending.

- [ ] **Step 2: Run — expect the holding case to FAIL**

Run: `bash tests/test-subagent-capture.sh`
Expected: `FAIL: holding-message stub was archived`

- [ ] **Step 3: Implement** — in `scripts/subagent-capture.sh`: move the `MIN` definition (line 62) up to just after the tool-count gate (line 52), then insert:

```bash
MIN="${SB_SUBAGENT_MIN_RESULT:-80}"

# R1.2 (HOOK-5): workflow subagents return their real answer via a structured
# tool call; the last TEXT block is then an interim "holding" message. If the
# FINAL assistant record carries a tool_use and no substantive text of its own,
# there is no final prose result — skip rather than archive boilerplate.
FINAL_CONTENT=$(jq -c 'select(.type == "assistant") | .message.content' "$TRANSCRIPT" 2>/dev/null | tail -1)
FINAL_TOOLS=$(printf '%s' "$FINAL_CONTENT" | jq -r '[.[]? | select(.type == "tool_use")] | length' 2>/dev/null)
FINAL_TEXT_LEN=$(printf '%s' "$FINAL_CONTENT" | jq -r '[.[]? | select(.type == "text") | .text] | join("")' 2>/dev/null | tr -d '[:space:]' | wc -c | tr -d ' ')
if [ "${FINAL_TOOLS:-0}" -ge 1 ] && [ "${FINAL_TEXT_LEN:-0}" -lt "$MIN" ]; then
  exit 0
fi
```

(and delete the original `MIN=` line further down so it is defined exactly once.)

- [ ] **Step 4: Run to GREEN**

Run: `bash tests/test-subagent-capture.sh`
Expected: `ALL PASS` (existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add scripts/subagent-capture.sh tests/test-subagent-capture.sh
git commit -m "fix(capture): skip workflow holding-message stubs in subagent capture (R1.2, HOOK-5)"
```

---

### Task 9: episodic_read path guard (R1.3 / MCP-SEC-1 — G-MCP-1 closure)

**Files:**
- Modify: `mcp/src/tools/episodic-search.ts` (new export), `mcp/src/server.ts` (line 17 import, ~line 426 tool registration, line 50 version)
- Create: `mcp/src/tools/episodic-read-guard.test.ts`

- [ ] **Step 1: Write the failing test** — create `mcp/src/tools/episodic-read-guard.test.ts`:

```ts
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { assertTranscriptPath } from './episodic-search.js';
import { PathGuardError } from '../path-guard.js';

describe('episodic_read path guard (G-MCP-1, R1.3)', () => {
  let brain: string;
  let outside: string;
  beforeAll(() => {
    brain = mkdtempSync(join(tmpdir(), 'sb-brain-'));
    mkdirSync(join(brain, 'transcripts'), { recursive: true });
    writeFileSync(join(brain, 'transcripts', 'ok.txt'),
      '--- session-meta ---\nsession_id: s\nproject_slug: p\ndate: 2026-06-10\n---\n\nbody\n');
    outside = mkdtempSync(join(tmpdir(), 'sb-secret-'));
    writeFileSync(join(outside, 'secret.txt'), 'SECRET');
    symlinkSync(join(outside, 'secret.txt'), join(brain, 'transcripts', 'link.txt'));
  });
  afterAll(() => {
    rmSync(brain, { recursive: true, force: true });
    rmSync(outside, { recursive: true, force: true });
  });

  it('accepts an absolute path inside transcripts/', () => {
    expect(assertTranscriptPath(brain, join(brain, 'transcripts', 'ok.txt'))).toContain('ok.txt');
  });
  it('rejects an absolute path outside transcripts/', () => {
    expect(() => assertTranscriptPath(brain, join(outside, 'secret.txt'))).toThrow(PathGuardError);
  });
  it('rejects ../ traversal', () => {
    expect(() => assertTranscriptPath(brain, '../../etc/passwd')).toThrow(PathGuardError);
  });
  it('rejects a symlink that escapes transcripts/', () => {
    expect(() => assertTranscriptPath(brain, join(brain, 'transcripts', 'link.txt'))).toThrow(PathGuardError);
  });
  it('rejects NUL bytes', () => {
    expect(() => assertTranscriptPath(brain, 'a\0b')).toThrow(PathGuardError);
  });
});
```

- [ ] **Step 2: Run — expect FAIL (no such export)**

Run: `cd mcp && npx vitest run src/tools/episodic-read-guard.test.ts`
Expected: FAIL — `assertTranscriptPath` is not exported.

- [ ] **Step 3: Implement the helper** — in `mcp/src/tools/episodic-search.ts`, ensure `join`, `relative`, `isAbsolute` are imported from `'path'` (merge with the existing path import) and add `import { assertWithin } from '../path-guard.js';`. Then add, just above `episodicRead`:

```ts
/**
 * episodic_read entry-point guard — the one G-MCP-1 surface the v0.21.0
 * hardening pass (commit 4837873) missed. The model-supplied path must
 * resolve inside ${brainDir}/transcripts, symlinks resolved BEFORE
 * validation (path-guard doctrine). Returns the validated real path.
 */
export function assertTranscriptPath(brainDir: string, filePath: string): string {
  const base = join(brainDir, 'transcripts');
  const rel = isAbsolute(filePath) ? relative(base, filePath) : filePath;
  return assertWithin(base, rel);
}
```

- [ ] **Step 4: Wire the server entry point** — `mcp/src/server.ts`:

(a) Line 17 — extend the import:

```ts
import { episodicSearch, episodicRead, assertTranscriptPath, buildEpisodicIndex, withActiveScope } from "./tools/episodic-search.js";
```

(b) In the `episodic_read` registration (~line 426): description becomes

```
Read full conversation context from a specific transcript file (must be inside the second-brain transcripts directory). Use after episodic_search to get complete exchange details.
```

(c) In its handler, replace the direct call (line ~437):

```ts
      const safePath = assertTranscriptPath(BRAIN_DIR, args.path);
      const result = await episodicRead(safePath, args.startLine, args.endLine);
```

(The handler's existing catch already returns `isError: true` with the message, so a `PathGuardError` surfaces as a clean tool error.)

(d) Line 50 — server version:

```ts
  { name: "knowledge-base", version: "2.6.8" },
```

- [ ] **Step 5: Typecheck + full vitest + rebuild the tracked bundle**

Run: `cd mcp && npx tsc --noEmit && npx vitest run && npm run bundle`
Expected: tsc clean; all vitest tests pass (464 existing + 5 new); bundle rebuilt → `git status` shows `mcp/dist` changes.

- [ ] **Step 6: Commit**

```bash
git add mcp/src/tools/episodic-search.ts mcp/src/tools/episodic-read-guard.test.ts mcp/src/server.ts mcp/dist
git commit -m "fix(mcp): episodic_read path guard — close the missed G-MCP-1 entry point (R1.3, server 2.6.8)"
```

---

### Task 10: Version bump, migration row, wiki convention note

- [ ] **Step 1: Bump versions**

- `.claude-plugin/plugin.json`: `"version": "0.24.38"`
- `.claude-plugin/marketplace.json`: the **second-brain** plugin entry's `version` → `"0.24.38"` (cost-router stays `0.1.1`).

- [ ] **Step 2: Migration row** — append a `0.24.38` row to the table in `skills/upgrade/SKILL.md`, following the exact format of the `0.24.37` row. Content:

> **0.24.38** — R1 extraction-loop fixes. (1) Capture/context hooks no-op under `SB_NESTED_SPAWN=1` (set automatically by the drainer/maintainer spawns; never set it in a live session or capture goes dark for that session). (2) Extraction markers are now session-keyed (`.last-extracted-line-<slug>--<session_id>`); legacy slug-keyed markers are inert and swept by the drainer's 7-day GC — no user action. (3) Drainer extractor timeout default 25s→120s (`SB_EXTRACT_TIMEOUT` still overrides); extractor input tail-capped at 200KB (`SB_EXTRACT_MAX_BYTES`); sub-1KB archive bodies skip the LLM (`SB_DRAIN_MIN_BYTES`). (4) MCP server 2.6.8: `episodic_read` now rejects paths outside `~/.second-brain/transcripts` (G-MCP-1 closure). No precondition — bumping the marker is sufficient.

- [ ] **Step 3: Wiki convention** (PROJECT.md convention: extraction-behavior changes update the extractor-health wiki page):

```bash
grep -rln 'extractor-health-banner-pattern' ~/knowledge/wiki --include='*.md' | head -1
```

Append a dated note to that page's body: *2026-06-10 (0.24.38): drainer spawns now export `SB_NESTED_SPAWN=1` (capture/context hooks no-op in nested sessions) and run from `~/.second-brain/scratch`; drainer timeout default is 120s; markers are session-keyed. A recurring `ec=124` in error-log.jsonl after this version indicates a genuinely slow/hung extractor, not the hook-self-load class.*

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json skills/upgrade/SKILL.md
git commit -m "release: 0.24.38 — R1 extraction-loop wave (nested-spawn guard, session-keyed markers, drainer budgets, episodic_read guard)"
```

---

### Task 11: Full verification + release gate + PR

- [ ] **Step 1: Full suite**

Run: `bash tests/run-all.sh`
Expected: 0 FAIL (109+3 new shell files; vitest 469). Budget ~3 min on the Pi.

- [ ] **Step 2: Plugin validation**

Run: `bash scripts/validate-plugin.sh`
Expected: exit 0, no version-drift complaints.

- [ ] **Step 3: Deep-review gate** (release discipline — required before merge)

Invoke `/second-brain:code-review-deep` on the branch. Address any confirmed findings, re-run the suite, amend/add commits.

- [ ] **Step 4: Push + PR**

```bash
git push -u origin fix/0.24.38-r1-extraction-loop
gh pr create --base main --title "fix: 0.24.38 — R1 extraction-loop wave (deep-dive)" --body "$(cat <<'EOF'
Implements wave R1 of docs/specs/2026-06-10-plugin-deep-dive-improvements-design.md:
- R1.1 nested-spawn circuit breaker (HOOK-2/3): SB_NESTED_SPAWN env + scratch cwd + 120s drainer timeout — kills the ec=124 class
- R1.2 idempotent capture (HOOK-1/4/5/10): session-keyed advancing markers, 200KB input cap, too-small fast-path, holding-stub skip, GC sweeps, PreCompact budget align
- R1.3 episodic_read path guard (MCP-SEC-1): the G-MCP-1 entry point v0.21.0 missed (server 2.6.8)

Evidence: docs/specs/2026-06-10-plugin-deep-dive-findings-appendix.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5: Post-merge smoke (manual, after the next drainer timer fire)**

Check `~/.second-brain/error-log.jsonl`: no new `ec=124` extractor-diag lines; `.extraction-state.jsonl` gaining `outcome:"ok"` lines (including `reason:"too-small"` for the ~50 pending stubs); `~/.second-brain/transcripts/` no longer accumulating duplicate windows.

---

## Plan self-review (done at authoring time)

- **Spec coverage:** HOOK-1 → Task 4; HOOK-2 → Tasks 2-3; HOOK-3 → Task 2; HOOK-4 → Task 6; HOOK-5 → Tasks 7-8; HOOK-10 → Task 4 Step 6b; MCP-SEC-1 → Task 9; marker GC + scratch GC → Task 5; release discipline → Tasks 10-11. HOOK-6 (pre-compact log misdiagnosis) needs no code — the nested-spawn guard removes its cause.
- **Known interaction risks called out inline:** legacy drain fixtures vs the fast-path (Task 7 Step 1), `test-lib-extractor-backend.sh` cwd assertions (Task 3 Step 6), Task 5's GC test must stay last in its file (re-exports HOME).
- **Type consistency:** `sb_extraction_marker_key` used in both hook scripts; `assertTranscriptPath(brainDir, filePath)` signature identical in helper, test, and server wiring.
