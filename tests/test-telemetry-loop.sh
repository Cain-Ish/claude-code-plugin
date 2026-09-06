#!/bin/bash
# pins: SB_CAPTURE_HEALTH_BANNER — silences this unrelated banner so only the telemetry manifest under test is asserted
# pins: SB_DISABLE_AUTO_TIMER — silences this unrelated timer banner so only the telemetry manifest under test is asserted
# pins: SB_LOOP_DEAD_BANNER — silences this unrelated banner so only the telemetry manifest under test is asserted
# pins: SB_TELEMETRY — kill-switch test: asserts =off suppresses the manifest write (Test 2)
# P1.2/P1.3/P1.4 telemetry loop (archive/docs branch, docs/plans/2026-07-13-p1-observability.md Tasks 2-4):
# session-load WRITES an injection manifest; stop-extract correlates it against the
# transcript's tool_use records EXACTLY ONCE (manifest deleted), folds Skill/Task
# invocations into utilization-counts.json, and emits ONE `gate=value-loop` TRACE row
# (ec=0 → audit-log via R6b). Observation only — the vitest firewall guards the
# consumer side; this test proves the producer side, kill switch, and fallbacks.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

BRAIN="$TMP/.second-brain"
KNOW="$TMP/knowledge"
WORKDIR="$TMP/demo"
STUB="$TMP/stub"; mkdir -p "$STUB" "$WORKDIR" "$BRAIN/projects/demo/codemap" "$KNOW/wiki/learnings"
printf '#!/bin/bash\nexit 0\n' > "$STUB/claude"; chmod +x "$STUB/claude"
printf '# PROJECT: demo\n\n## Goal\ntelemetry demo\n' > "$BRAIN/projects/demo/PROJECT.md"

# Code map so session-load's §0d emits (and manifests) spine paths.
cat > "$BRAIN/projects/demo/codemap/map.md" <<'EOF'
src/core/router.ts — route, dispatch
src/core/store.ts — load, save
EOF

# A wiki page CREATED YESTERDAY → a Read hit on it counts as prior-session reuse (P1.4).
YESTERDAY=$(date -u -d '1 day ago' +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)
printf -- '---\ntitle: "Old Learning"\ndescription: ""\ntype: learnings\ncreated: %s\nupdated: %s\ntags: []\nrelated: []\n---\n\nbody\n' \
  "$YESTERDAY" "$YESTERDAY" > "$KNOW/wiki/learnings/old-learning.md"

SID="telemetry-test-1234"

run_session_load() {
  (cd "$WORKDIR" && printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"%s"}' "$SID" \
    | env PATH="$STUB:$PATH" HOME="$TMP" CLAUDE_PROJECT_DIR="$WORKDIR" \
          BRAIN_DIR="$BRAIN" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" ANTHROPIC_API_KEY="" \
          SB_CAPTURE_HEALTH_BANNER=off SB_DISABLE_AUTO_TIMER=1 SB_LOOP_DEAD_BANNER=off \
          "$@" bash "$ROOT/scripts/session-load.sh" 2>/dev/null)
}

MANIFEST="$BRAIN/.injected-manifest-$SID.jsonl"

# --- Test 1: session-load writes the manifest (codemap entries, sanitized sid) ---
run_session_load >/dev/null
[ -f "$MANIFEST" ] || fail "injection manifest not written by session-load"
grep -q '"kind":"codemap","id":"src/core/router.ts"' "$MANIFEST" || fail "codemap spine path missing from manifest"
pass "session-load writes the injection manifest (codemap entries)"

# --- Test 2: SB_TELEMETRY=off suppresses the manifest write ---
rm -f "$MANIFEST"
run_session_load SB_TELEMETRY=off >/dev/null
[ -f "$MANIFEST" ] && fail "SB_TELEMETRY=off must suppress the manifest"
pass "SB_TELEMETRY=off suppresses the manifest write"

# --- Build the session artifacts for the Stop side ---
# Manifest: 2 codemap paths + 1 wiki slug (as session-load would have written).
cat > "$MANIFEST" <<'EOF'
{"kind":"codemap","id":"src/core/router.ts"}
{"kind":"codemap","id":"src/core/store.ts"}
{"kind":"wiki","id":"old-learning"}
EOF
# Transcript: Read hits router.ts (codemap hit) + the wiki page (wiki hit, prior),
# store.ts never touched (miss); one Skill + one Task invocation for utilization.
T="$TMP/transcript.jsonl"
cat > "$T" <<EOF
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"C:\\\\repo\\\\src\\\\core\\\\router.ts"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"$KNOW/wiki/learnings/old-learning.md"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"second-brain:query"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Task","input":{"subagent_type":"second-brain:raw-drainer","prompt":"x"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
EOF

run_stop() {
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$T" "$WORKDIR" "$SID" \
    | env PATH="$STUB:$PATH" HOME="$TMP" BRAIN_DIR="$BRAIN" \
          CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" ANTHROPIC_API_KEY="" \
          "$@" bash "$ROOT/scripts/stop-extract.sh" >/dev/null 2>&1
}

# --- Test 3: stop-extract correlates + folds + emits the TRACE row, once ---
run_stop; RC=$?
[ "$RC" -eq 0 ] || fail "stop-extract non-zero exit ($RC)"
[ -f "$MANIFEST" ] && fail "manifest must be consumed (deleted) after correlation"
UTIL="$BRAIN/utilization-counts.json"
[ -f "$UTIL" ] || fail "utilization-counts.json not written"
jq -e '."skill:second-brain:query".count == 1' "$UTIL" >/dev/null || fail "skill invocation not counted: $(cat "$UTIL")"
jq -e '."agent:second-brain:raw-drainer".count == 1' "$UTIL" >/dev/null || fail "agent invocation not counted"
ROW=$(grep 'gate=value-loop' "$BRAIN/audit-log.jsonl" 2>/dev/null | tail -1)
[ -n "$ROW" ] || fail "value-loop TRACE row missing from audit-log (R6b routing)"
echo "$ROW" | grep -q 'injected=3 read=2 prior=1' || fail "correlation wrong (want injected=3 read=2 prior=1): $ROW"
echo "$ROW" | grep -q 'old-learning' || fail "hit slugs missing from the row: $ROW"
pass "correlation: injected=3 read=2 prior=1, counts folded, manifest consumed"

# --- Test 4: second Stop with no manifest → no second value-loop row, no crash ---
N_BEFORE=$(grep -c 'gate=value-loop' "$BRAIN/audit-log.jsonl")
run_stop || fail "stop-extract crashed on the no-manifest path"
N_AFTER=$(grep -c 'gate=value-loop' "$BRAIN/audit-log.jsonl")
[ "$N_AFTER" -eq "$N_BEFORE" ] || fail "value-loop must be exactly-once per session (manifest-gated)"
pass "no manifest → no duplicate row (exactly-once)"

# --- Test 5: SB_TELEMETRY=off on the Stop side — manifest untouched, no counts fold ---
cat > "$MANIFEST" <<'EOF'
{"kind":"codemap","id":"src/core/router.ts"}
EOF
cp "$UTIL" "$TMP/util-before.json"
run_stop SB_TELEMETRY=off || fail "stop-extract crashed with telemetry off"
[ -f "$MANIFEST" ] || fail "SB_TELEMETRY=off must leave the manifest untouched"
diff -q "$UTIL" "$TMP/util-before.json" >/dev/null || fail "SB_TELEMETRY=off must not fold counts"
pass "SB_TELEMETRY=off skips the Stop-side pass"

echo; echo "ALL PASS"
