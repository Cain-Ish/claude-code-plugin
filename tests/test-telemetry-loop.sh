#!/bin/bash
# pins: SB_CAPTURE_HEALTH_BANNER — silences this unrelated banner so only the telemetry manifest under test is asserted
# pins: SB_DISABLE_AUTO_TIMER — silences this unrelated timer banner so only the telemetry manifest under test is asserted
# pins: SB_LOOP_DEAD_BANNER — silences this unrelated banner so only the telemetry manifest under test is asserted
# pins: SB_TELEMETRY — kill-switch test: asserts =off suppresses the manifest write (Test 2)
# pins: SB_PERSONA_WIKI_MIN_SCORE — forces a per-prompt wiki hit so persona-context.sh's manifest write is exercised (Test 6)
# pins: SB_MANIFEST_SESSION_ID — names the manifest for a direct sb_manifest_add call (Test 15, unwritable-manifest fail-loud)
# run-all-timeout: 480   (~23 full Stop-hook invocations by design — cumulative/cross-Stop cases; each ~5-13s on MSYS under load, same class as test-stop-extract)
# P1.2/P1.3/P1.4 telemetry loop (archive/docs branch, docs/plans/2026-07-13-p1-observability.md Tasks 2-4):
# session-load AND persona-context WRITE to the injection manifest (single-source
# sb_manifest_add in lib.sh); stop-extract correlates it against the transcript's
# tool_use records CUMULATIVELY across Stops (manifest is never deleted — a
# per-session state file carries the running sets/counters forward), folds
# Agent/Task invocations into utilization-counts.json, and emits ONE `gate=value-loop`
# TRACE row PER STOP (cumulative numbers; readers take the LAST row per sid).
# Observation only — the vitest firewall guards the consumer side; this test proves
# the producer side, kill switch, and fallbacks.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

BRAIN="$TMP/.second-brain"
KNOW="$TMP/knowledge"
WORKDIR="$TMP/demo"
STUB="$TMP/stub"; mkdir -p "$STUB" "$WORKDIR" "$BRAIN/projects/demo/codemap" "$KNOW/wiki/learnings" "$KNOW/graph"
printf '#!/bin/bash\nexit 0\n' > "$STUB/claude"; chmod +x "$STUB/claude"
printf '# PROJECT: demo\n\n## Goal\ntelemetry demo\n\n## Cross-references\n- [[xref-page]]\n' > "$BRAIN/projects/demo/PROJECT.md"

# Code map so session-load's §0d emits (and manifests) spine paths.
cat > "$BRAIN/projects/demo/codemap/map.md" <<'EOF'
src/core/router.ts — route, dispatch
src/core/store.ts — load, save
EOF

# Graph: the project slug ("demo") has no edges of its own — it resolves through
# graph/project-registry.jsonl to its anchor entity ("demo-anchor"), which DOES
# have an edge. This is the project-first-seeding path (test-session-load-graph.sh
# Test 3) — it must manifest as kind:"anchor" id:"demo", never kind:"graph" (D-bug 3).
{
  printf '%s\n' '{"op":"assert","from":"hub-learning","to":"demo-anchor","type":"part_of","valid_from":"2026-05-29","recorded_at":"2026-05-29T00:00:00Z"}'
  printf '%s\n' '{"op":"assert","from":"xref-page","to":"xref-neighbor","type":"relates","valid_from":"2026-05-29","recorded_at":"2026-05-29T00:00:00Z"}'
} > "$KNOW/graph/edges.jsonl"
printf '%s\n' '{"anchor":"demo-anchor","project":"demo"}' > "$KNOW/graph/project-registry.jsonl"

# A wiki page CREATED YESTERDAY → a Read hit on it counts as prior-session reuse (P1.4).
YESTERDAY=$(date -u -d '1 day ago' +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)
printf -- '---\ntitle: "Old Learning"\ndescription: ""\ntype: learnings\ncreated: %s\nupdated: %s\ntags: []\nrelated: []\n---\n\nbody\n' \
  "$YESTERDAY" "$YESTERDAY" > "$KNOW/wiki/learnings/old-learning.md"

SID="telemetry-test-1234"

run_session_load() {
  (cd "$WORKDIR" && printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"%s"}' "$SID" \
    | env PATH="$STUB:$PATH" HOME="$TMP" CLAUDE_PROJECT_DIR="$WORKDIR" \
          BRAIN_DIR="$BRAIN" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" CLAUDE_PLUGIN_ROOT="$ROOT" ANTHROPIC_API_KEY="" \
          SB_CAPTURE_HEALTH_BANNER=off SB_DISABLE_AUTO_TIMER=1 SB_LOOP_DEAD_BANNER=off \
          "$@" bash "$ROOT/scripts/session-load.sh" 2>/dev/null)
}

MANIFEST="$BRAIN/.injected-manifest-$SID.jsonl"

# --- Test 1: session-load writes the manifest (codemap entries, sanitized sid) ---
run_session_load >/dev/null
[ -f "$MANIFEST" ] || fail "injection manifest not written by session-load"
grep -q '"kind":"codemap","id":"src/core/router.ts"' "$MANIFEST" || fail "codemap spine path missing from manifest"
pass "session-load writes the injection manifest (codemap entries)"

# --- Test 1b: the graph block's PROJECT-ANCHOR seed manifests as kind:"anchor", ---
# not kind:"graph" — the "ritual call" bug (D-bug 3). The using-second-brain skill
# tells Claude to call knowledge_neighbors on the project anchor every session; that
# call must be excluded from injected/read, tracked separately as "ritual" instead.
grep -q '"kind":"anchor","id":"demo"' "$MANIFEST" || fail "project-anchor seed not manifested as kind:anchor: $(cat "$MANIFEST")"
grep -q '"kind":"graph","id":"demo"' "$MANIFEST" && fail "project-anchor seed STILL manifested as kind:graph (ritual bug not fixed)"
pass "session-load manifests the project-anchor graph seed as kind:anchor, not kind:graph"

# --- Test 1c: a SECOND graph seed (an explicit Cross-references slug) stays ---
# kind:graph, never kind:anchor — proves the anchor label is the FIRST-successful-
# seed rule, not "every graph seed" or "the project slug unconditionally".
grep -q '"kind":"graph","id":"xref-page"' "$MANIFEST" || fail "cross-reference seed not manifested as kind:graph: $(cat "$MANIFEST")"
grep -q '"kind":"anchor","id":"xref-page"' "$MANIFEST" && fail "cross-reference seed wrongly manifested as kind:anchor"
pass "a second (cross-reference) graph seed manifests as kind:graph, not kind:anchor"

# --- Test 2: SB_TELEMETRY=off suppresses the manifest write ---
rm -f "$MANIFEST"
run_session_load SB_TELEMETRY=off >/dev/null
[ -f "$MANIFEST" ] && fail "SB_TELEMETRY=off must suppress the manifest"
pass "SB_TELEMETRY=off suppresses the manifest write"

# --- Build the session artifacts for the Stop side ---
# Manifest: 2 codemap paths + 1 wiki slug + 1 anchor id (as session-load would have
# written across the codemap + wiki + graph-anchor blocks).
cat > "$MANIFEST" <<'EOF'
{"kind":"codemap","id":"src/core/router.ts"}
{"kind":"codemap","id":"src/core/store.ts"}
{"kind":"wiki","id":"old-learning"}
{"kind":"anchor","id":"demo-anchor"}
EOF
# Transcript: Read hits router.ts (codemap hit) + the wiki page (wiki hit, prior),
# store.ts never touched (miss); one Skill + one Task invocation for utilization;
# one Agent invocation (model:sonnet) alongside the Task (no model) for agents/tiers;
# one knowledge_search pull; one knowledge_neighbors call on the anchor id (ritual hit
# — also counts toward "pulled", since knowledge_neighbors matches both regexes).
T="$TMP/transcript.jsonl"
cat > "$T" <<EOF
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"C:\\\\repo\\\\src\\\\core\\\\router.ts"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"$KNOW/wiki/learnings/old-learning.md"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"second-brain:query"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Task","input":{"subagent_type":"second-brain:raw-drainer","prompt":"x"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent","input":{"model":"sonnet","subagent_type":"fork"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"mcp__plugin_second-brain_knowledge-base__knowledge_search","input":{"query":"x"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"mcp__plugin_second-brain_knowledge-base__knowledge_neighbors","input":{"slug":"demo-anchor"}}]}}
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
[ -f "$MANIFEST" ] || fail "manifest must be KEPT (cumulative across Stops), not deleted"
STATE="$BRAIN/.value-loop-state-$SID.json"
[ -f "$STATE" ] || fail "per-session value-loop state file not written: $STATE"
UTIL="$BRAIN/utilization-counts.json"
[ -f "$UTIL" ] || fail "utilization-counts.json not written"
jq -e '."skill:second-brain:query".count == 1' "$UTIL" >/dev/null || fail "skill invocation not counted: $(cat "$UTIL")"
jq -e '."agent:second-brain:raw-drainer".count == 1' "$UTIL" >/dev/null || fail "Task agent invocation not counted"
jq -e '."agent:fork".count == 1' "$UTIL" >/dev/null || fail "Agent (renamed Task tool) invocation not counted in utilization fold — bug 1 not fixed: $(cat "$UTIL")"
ROW=$(grep 'gate=value-loop' "$BRAIN/audit-log.jsonl" 2>/dev/null | tail -1)
[ -n "$ROW" ] || fail "value-loop TRACE row missing from audit-log (R6b routing)"
echo "$ROW" | grep -q 'injected=3 read=2 prior=1' || fail "correlation wrong (want injected=3 read=2 prior=1): $ROW"
echo "$ROW" | grep -q 'old-learning' || fail "hit slugs missing from the row: $ROW"
echo "$ROW" | grep -qE 'hits=[^ ]*demo-anchor' && fail "anchor id leaked into hits= / read= (must be excluded): $ROW"
echo "$ROW" | grep -q 'ritual=1' || fail "anchor fetch not counted as ritual=1: $ROW"
echo "$ROW" | grep -q 'agents=2' || fail "agents= wrong (want 2: one Task + one Agent): $ROW"
echo "$ROW" | grep -q 'tiers=' || fail "tiers= field missing: $ROW"
echo "$ROW" | grep -qE 'tiers=[^ ]*sonnet:1' || fail "tiers= missing sonnet:1 (Agent call with input.model=sonnet): $ROW"
echo "$ROW" | grep -qE 'tiers=[^ ]*unset:1' || fail "tiers= missing unset:1 (Task call with no input.model): $ROW"
echo "$ROW" | grep -qE 'pulled=[0-9]' || fail "pulled= field missing: $ROW"
# pulled= counts pulls Claude makes on its OWN INITIATIVE, counted apart from the
# ritual anchor fetch (ritual=1) and reads of already-injected ids (read=). The
# knowledge_neighbors call here targets the manifested anchor id (demo-anchor) —
# it is the ritual call, not a second "pull". Only knowledge_search (no target) counts.
echo "$ROW" | grep -q 'pulled=1' || fail "pulled= wrong (want 1: knowledge_search only — the knowledge_neighbors call on the anchor is ritual=, not pulled=): $ROW"
echo "$ROW" | grep -q 'turn=1' || fail "turn= wrong on the first Stop (want 1): $ROW"
echo "$ROW" | grep -q "sid=$SID" || fail "sid= missing or wrong: $ROW"
pass "correlation: injected=3 read=2 prior=1 ritual=1 agents=2 tiers=sonnet:1,unset:1 pulled=1 turn=1, counts folded, manifest KEPT"

# --- Test 3b: a fetch of an id NOT in the manifest IS an own-initiative pull ---
cat >> "$T" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"mcp__plugin_second-brain_knowledge-base__knowledge_fetch","input":{"slug":"unrelated-page"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"more"}]}}
EOF
run_stop; RC=$?
[ "$RC" -eq 0 ] || fail "stop-extract (Test 3b, own-initiative fetch) non-zero exit ($RC)"
ROW3B=$(grep 'gate=value-loop' "$BRAIN/audit-log.jsonl" 2>/dev/null | grep "sid=$SID" | tail -1)
echo "$ROW3B" | grep -q 'pulled=2' || fail "own-initiative fetch of a non-manifested id should bump pulled to 2: $ROW3B"
pass "a fetch of an id NOT in the manifest counts as pulled= (own initiative)"

# --- Test 4: a SECOND Stop on a GROWING transcript is CUMULATIVE, not a duplicate-or-nothing ---
# Turn-1 window (above) had no fetch of a not-yet-hit wiki slug; here a fresh session
# proves the cross-Stop merge explicitly: turn-1 has zero fetches of its injected slug,
# turn-2's NEW window fetches it — the second row must show read=1, turn=2 (cumulative),
# not read=0 (state lost) and not read=1 counted twice.
SID2="telemetry-test-cumulative"
MANIFEST2="$BRAIN/.injected-manifest-$SID2.jsonl"
STATE2="$BRAIN/.value-loop-state-$SID2.json"
mkdir -p "$BRAIN/projects/demo2"
printf '# PROJECT: demo2\n\n## Goal\ncumulative demo\n' > "$BRAIN/projects/demo2/PROJECT.md"
WORKDIR2="$TMP/demo2"; mkdir -p "$WORKDIR2"
cat > "$MANIFEST2" <<'EOF'
{"kind":"wiki","id":"old-learning"}
EOF
T2="$TMP/transcript2.jsonl"
cat > "$T2" <<EOF
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"$WORKDIR2/unrelated.ts"}}]}}
EOF
run_stop2() {
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$T2" "$WORKDIR2" "$SID2" \
    | env PATH="$STUB:$PATH" HOME="$TMP" BRAIN_DIR="$BRAIN" \
          CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" ANTHROPIC_API_KEY="" \
          bash "$ROOT/scripts/stop-extract.sh" >/dev/null 2>&1
}
run_stop2; RC=$?
[ "$RC" -eq 0 ] || fail "stop-extract (turn 1, cumulative session) non-zero exit ($RC)"
ROW1=$(grep 'gate=value-loop' "$BRAIN/audit-log.jsonl" 2>/dev/null | grep "sid=$SID2" | tail -1)
[ -n "$ROW1" ] || fail "turn-1 value-loop row missing for cumulative session"
echo "$ROW1" | grep -q 'read=0' || fail "turn-1 read should be 0 (no fetch yet): $ROW1"
echo "$ROW1" | grep -q 'turn=1' || fail "turn-1 turn= should be 1: $ROW1"
[ -f "$MANIFEST2" ] || fail "manifest must persist after turn-1 Stop (no delete-on-first-Stop, bug 2)"
# Turn 2: append new lines that fetch the injected wiki slug. The marker has
# advanced past T2's turn-1 lines, so stop-extract sees only these as new.
cat >> "$T2" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"$KNOW/wiki/learnings/old-learning.md"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
EOF
run_stop2; RC=$?
[ "$RC" -eq 0 ] || fail "stop-extract (turn 2, cumulative session) non-zero exit ($RC)"
ROW2=$(grep 'gate=value-loop' "$BRAIN/audit-log.jsonl" 2>/dev/null | grep "sid=$SID2" | tail -1)
[ -n "$ROW2" ] || fail "turn-2 value-loop row missing"
[ "$ROW1" = "$ROW2" ] && fail "turn-2 row identical to turn-1 (no new row emitted — bug 2 not fixed)"
echo "$ROW2" | grep -q 'read=1' || fail "turn-2 read should be 1 (cumulative hit): $ROW2"
echo "$ROW2" | grep -q 'turn=2' || fail "turn-2 turn= should be 2 (Stop count for this session): $ROW2"
pass "two Stops on a growing transcript: turn-1 read=0/turn=1, turn-2 read=1/turn=2 (cumulative, whole-session)"

# --- Test 4b: hits= EMPTY (the common read=0 case) must not field-shift later columns ---
# `IFS=$'\t' read` COLLAPSES consecutive tabs (tab is an IFS-whitespace char), so an
# empty hits= field between two non-empty fields silently ate the NEXT field's value
# in the old @tsv parse. A session with an injected-but-never-read wiki id (hits=
# empty) AND an Agent call (agents/tiers non-empty) is the minimal repro.
SID3="telemetry-test-fieldshift"
MANIFEST3="$BRAIN/.injected-manifest-$SID3.jsonl"
WORKDIR3="$TMP/demo3"; mkdir -p "$WORKDIR3"
mkdir -p "$BRAIN/projects/demo3"
printf '# PROJECT: demo3\n\n## Goal\nfield-shift demo\n' > "$BRAIN/projects/demo3/PROJECT.md"
cat > "$MANIFEST3" <<'EOF'
{"kind":"wiki","id":"never-read"}
EOF
T3="$TMP/transcript3.jsonl"
cat > "$T3" <<EOF
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent","input":{"model":"sonnet","subagent_type":"fork"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
EOF
printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$T3" "$WORKDIR3" "$SID3" \
  | env PATH="$STUB:$PATH" HOME="$TMP" BRAIN_DIR="$BRAIN" \
        CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" ANTHROPIC_API_KEY="" \
        bash "$ROOT/scripts/stop-extract.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] || fail "stop-extract (field-shift case) non-zero exit ($RC)"
ROW3=$(grep 'gate=value-loop' "$BRAIN/audit-log.jsonl" 2>/dev/null | grep "sid=$SID3" | tail -1)
[ -n "$ROW3" ] || fail "field-shift case: value-loop row missing"
echo "$ROW3" | grep -q 'read=0' || fail "field-shift case: read should be 0: $ROW3"
echo "$ROW3" | grep -q 'hits=none' || fail "field-shift case: hits should be 'none' (empty), unshifted: $ROW3"
echo "$ROW3" | grep -q 'agents=1' || fail "field-shift case: agents should be 1: $ROW3"
echo "$ROW3" | grep -q 'tiers=sonnet:1' || fail "field-shift case: tiers should be sonnet:1, not swallowed into hits=: $ROW3"
echo "$ROW3" | grep -qE 'hits=[^ ]*sonnet' && fail "field-shift bug reproduced: tiers value leaked into hits=: $ROW3"
pass "hits= empty does not field-shift ritual=/pulled=/agents=/tiers=/turn=/sid="

# --- Test 5: SB_TELEMETRY=off on the Stop side — manifest untouched, no counts fold, no new row ---
# Must reach the telemetry block to be a real test: append NEW lines first (Test 3b's
# run_stop already advanced the extraction marker to end-of-transcript, so a bare
# replay would exit at gate=no-new-lines BEFORE telemetry is ever touched, making
# this vacuous — deleting the Stop-side SB_TELEMETRY guard would still pass it).
TURN_BEFORE_T5=$(jq -r '.turn' "$STATE")
cat >> "$T" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent","input":{"model":"haiku","subagent_type":"fork"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"mcp__plugin_second-brain_knowledge-base__knowledge_search","input":{"query":"y"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"still going"}]}}
EOF
N_BEFORE=$(grep -c 'gate=value-loop' "$BRAIN/audit-log.jsonl")
cp "$UTIL" "$TMP/util-before.json"
run_stop SB_TELEMETRY=off || fail "stop-extract crashed with telemetry off"
N_AFTER=$(grep -c 'gate=value-loop' "$BRAIN/audit-log.jsonl")
[ "$N_AFTER" -eq "$N_BEFORE" ] || fail "SB_TELEMETRY=off must not emit a new value-loop row"
diff -q "$UTIL" "$TMP/util-before.json" >/dev/null || fail "SB_TELEMETRY=off must not fold counts"
TURN_AFTER_T5=$(jq -r '.turn' "$STATE")
[ "$TURN_AFTER_T5" = "$TURN_BEFORE_T5" ] || fail "SB_TELEMETRY=off must not advance the value-loop state's turn: $TURN_BEFORE_T5 -> $TURN_AFTER_T5"
pass "SB_TELEMETRY=off skips the Stop-side pass entirely (fixture actually reaches the telemetry block)"

# CONTROL: append one more line and run WITHOUT the flag — proves the fixture
# reaches the telemetry block at all (a deleted Stop-side guard would go RED above
# but this control would still be green; both together lock the real behavior).
cat >> "$T" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"control line"}]}}
EOF
run_stop || fail "stop-extract crashed on the Test 5 control run"
N_CONTROL=$(grep -c 'gate=value-loop' "$BRAIN/audit-log.jsonl")
[ "$N_CONTROL" -gt "$N_AFTER" ] || fail "Test 5 control: a Stop WITHOUT SB_TELEMETRY=off must emit a new value-loop row"
TURN_CONTROL=$(jq -r '.turn' "$STATE")
[ "$TURN_CONTROL" -gt "$TURN_AFTER_T5" ] || fail "Test 5 control: turn should have advanced past $TURN_AFTER_T5: $TURN_CONTROL"
pass "control: a Stop without the flag advances turn and emits a new row (fixture is not vacuous)"

# --- Test 6: persona-context.sh's per-prompt wiki injection lands in the manifest ---
# (bug 4) — session-load is NOT the only writer any more. Reuses the injection-wrap
# test's technique (SB_PERSONA_WIKI_MIN_SCORE=0 pins the retrieval floor open so a
# hit is guaranteed) and the existing widget-calibration-style wiki fixture.
PBRAIN="$TMP/.second-brain-pc"
PKNOW="$TMP/knowledge-pc"
mkdir -p "$PBRAIN" "$PKNOW/wiki/learnings"
printf -- '---\ntitle: widget calibration\ndescription: how to calibrate the widget\ntype: learnings\ncreated: 2026-01-01\nupdated: 2026-01-01\ntags: []\nrelated: []\n---\n\n# widget calibration\n\nbody\n' \
  > "$PKNOW/wiki/learnings/widget-calibration.md"
# A SECOND matching page. A regression to session-load.sh's greedy single-slug-
# per-line extraction form (`.*\[\[\([^]]*\)\]\].*`) would drop every hit but one
# per prompt — one page alone can't distinguish that from the correct per-token form.
printf -- '---\ntitle: widget calibration history\ndescription: widget calibration record\ntype: learnings\ncreated: 2026-01-01\nupdated: 2026-01-01\ntags: []\nrelated: []\n---\n\n# widget calibration history\n\nbody\n' \
  > "$PKNOW/wiki/learnings/widget-calibration-history.md"
PSID="persona-manifest-test"
PMANIFEST="$PBRAIN/.injected-manifest-$PSID.jsonl"
PCOUT=$(printf '{"session_id":"%s","prompt":"investigate the widget calibration procedure documented in the wiki"}' "$PSID" \
  | env HOME="$TMP" BRAIN_DIR="$PBRAIN" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$PKNOW" CLAUDE_PLUGIN_ROOT="$ROOT" \
        SB_PERSONA_WIKI_MIN_SCORE=0 bash "$ROOT/scripts/persona-context.sh" 2>/dev/null)
printf '%s' "$PCOUT" | grep -q 'widget-calibration' \
  || fail "persona-context did not surface the widget-calibration wiki hit — cannot exercise the manifest write ($PCOUT)"
[ -f "$PMANIFEST" ] || fail "persona-context's per-prompt wiki hit was not written to the injection manifest (bug 4 not fixed)"
grep -q '"kind":"wiki","id":"widget-calibration"' "$PMANIFEST" \
  || fail "persona-context manifest missing the expected wiki entry: $(cat "$PMANIFEST" 2>/dev/null || echo '<missing>')"
grep -q '"kind":"wiki","id":"widget-calibration-history"' "$PMANIFEST" \
  || fail "persona-context manifest missing the SECOND wiki hit (greedy single-slug extraction regression): $(cat "$PMANIFEST" 2>/dev/null || echo '<missing>')"
printf '%s' "$PCOUT" | grep -q 'widget-calibration-history' \
  || fail "persona-context did not surface the second widget-calibration-history hit in emitted context: $PCOUT"
pass "persona-context.sh's per-prompt wiki injection lands in the manifest for BOTH hits (kind:wiki)"

# --- Test 7: sb_manifest_add is a single source in lib.sh, called from both writers ---
# Comment-stripped CALL check (not a bare `grep -q name`, which also matches a
# comment mentioning the function name — verified: persona-context.sh's only
# non-comment occurrence is the real call, so a naive grep can't distinguish
# "commented the call out" from "still calling it").
grep -q '^sb_manifest_add()' "$ROOT/scripts/lib.sh" || fail "sb_manifest_add must be defined in lib.sh (single source)"
grep -q '^sb_manifest_add()' "$ROOT/scripts/session-load.sh" && fail "session-load.sh must not redefine sb_manifest_add (lib.sh is the single source)"
for _f in persona-context.sh session-load.sh; do
  grep -v '^[[:space:]]*#' "$ROOT/scripts/$_f" | grep -qE '(^|[;&|[:space:]])sb_manifest_add[[:space:]]' \
    || fail "$_f does not CALL sb_manifest_add (comment-stripped check)"
done
pass "sb_manifest_add lives only in lib.sh; both session-load.sh and persona-context.sh CALL it"

# --- Test 8: a LARGE manifest must not blow the Windows ~32K CreateProcess argv cap ---
# The manifest/state used to be passed to jq via --argjson/--arg (command-line
# arguments). persona-context appends per PROMPT, so a long session's manifest can
# grow into the thousands of lines; a Read-heavy turn's window text has the same
# risk. --rawfile (or stdin) is not subject to that limit — this proves a big
# manifest still produces a row instead of jq silently failing to even start.
# 30000 lines (~1.2MB, generated via awk — not a per-line bash loop) is deliberately
# well past every platform's per-arg cap (Linux MAX_ARG_STRLEN=131072, Windows
# CreateProcess ~32K); a 3000-line/~113KB manifest stayed under Linux's own cap and
# could not go RED there on the exact --arg/--argjson regression this test names.
SID4="telemetry-test-bigmanifest"
MANIFEST4="$BRAIN/.injected-manifest-$SID4.jsonl"
WORKDIR4="$TMP/demo4"; mkdir -p "$WORKDIR4"
mkdir -p "$BRAIN/projects/demo4"
printf '# PROJECT: demo4\n\n## Goal\nbig manifest demo\n' > "$BRAIN/projects/demo4/PROJECT.md"
awk 'BEGIN{for(i=0;i<30000;i++) printf "{\"kind\":\"wiki\",\"id\":\"bulk-page-%d\"}\n", i}' > "$MANIFEST4"
T4="$TMP/transcript4.jsonl"
cat > "$T4" <<EOF
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"mcp__plugin_second-brain_knowledge-base__knowledge_fetch","input":{"slug":"bulk-page-7"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
EOF
printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$T4" "$WORKDIR4" "$SID4" \
  | env PATH="$STUB:$PATH" HOME="$TMP" BRAIN_DIR="$BRAIN" \
        CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" ANTHROPIC_API_KEY="" \
        bash "$ROOT/scripts/stop-extract.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] || fail "stop-extract (30000-line manifest) non-zero exit ($RC)"
ROW4=$(grep 'gate=value-loop' "$BRAIN/audit-log.jsonl" 2>/dev/null | grep "sid=$SID4" | tail -1)
[ -n "$ROW4" ] || fail "30000-line manifest: value-loop row missing — argv-limit bug (jq call failed silently)"
echo "$ROW4" | grep -q 'injected=30000' || fail "30000-line manifest: injected should be 30000: $ROW4"
echo "$ROW4" | grep -q 'read=1' || fail "30000-line manifest: read should be 1 (bulk-page-7 fetched): $ROW4"
pass "a 30000-line manifest still produces a correct row (no argv-limit failure)"

# Source-scan lock: the manifest/state must never be passed via --arg/--argjson
# (that would be invisible on Linux/macOS CI at any reasonable manifest size).
grep -v '^[[:space:]]*#' "$ROOT/scripts/stop-extract.sh" | grep -qE -- '--(arg|argjson) +(mraw|sraw)' \
  && fail "stop-extract.sh must pass the manifest/state via --rawfile, never --arg/--argjson"
pass "manifest/state are passed to jq via --rawfile, never --arg/--argjson (source-scan lock)"

# --- Test 9: a TORN trailing line in the transcript WINDOW must not abort the pass ---
# A Stop can read the transcript while Claude Code is still mid-write on the final
# line. `jq -s` (slurp-parse-as-you-go) errors on the FIRST malformed value and
# produces nothing; the fix parses the window tolerantly (raw-slurp + per-line
# try/catch), same as the manifest parse.
SID5="telemetry-test-tornline"
MANIFEST5="$BRAIN/.injected-manifest-$SID5.jsonl"
WORKDIR5="$TMP/demo5"; mkdir -p "$WORKDIR5"
mkdir -p "$BRAIN/projects/demo5"
printf '# PROJECT: demo5\n\n## Goal\ntorn line demo\n' > "$BRAIN/projects/demo5/PROJECT.md"
cat > "$MANIFEST5" <<'EOF'
{"kind":"wiki","id":"old-learning"}
EOF
T5="$TMP/transcript5.jsonl"
{
  printf '{"type":"user","message":{"role":"user","content":"go"}}\n'
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"%s/wiki/learnings/old-learning.md"}}]}}\n' "$KNOW"
  # Trailing torn line — no closing braces, simulating a Stop that read mid-write.
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","inp'
} > "$T5"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$T5" "$WORKDIR5" "$SID5" \
  | env PATH="$STUB:$PATH" HOME="$TMP" BRAIN_DIR="$BRAIN" \
        CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" ANTHROPIC_API_KEY="" \
        bash "$ROOT/scripts/stop-extract.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] || fail "stop-extract (torn trailing line) non-zero exit ($RC)"
ROW5=$(grep 'gate=value-loop' "$BRAIN/audit-log.jsonl" 2>/dev/null | grep "sid=$SID5" | tail -1)
[ -n "$ROW5" ] || fail "torn trailing line: value-loop row missing — the whole pass aborted on the bad line"
echo "$ROW5" | grep -q 'read=1' || fail "torn trailing line: the earlier CLEAN line's hit should still count: $ROW5"
pass "a torn trailing line in the transcript window does not abort the value-loop pass"

# --- Test 10: telemetry has its OWN watermark, independent of the extraction marker ---
# Delete the extraction marker (what a merge-failed Stop leaves behind) and re-run
# stop-extract on the SAME unchanged transcript. The extraction-side re-scans (by
# design — the marker didn't advance), but telemetry's own scanned_to watermark
# must stop it from double-counting pulled/agents/tiers/turn again.
STATE1="$BRAIN/.value-loop-state-$SID.json"
PULLED_BEFORE=$(jq -r '.pulled' "$STATE1")
AGENTS_BEFORE=$(jq -r '.agents' "$STATE1")
TURN_BEFORE=$(jq -r '.turn' "$STATE1")
rm -f "$BRAIN"/.last-extracted-line-*
run_stop; RC=$?
[ "$RC" -eq 0 ] || fail "stop-extract (marker-deleted retry) non-zero exit ($RC)"
ROW10=$(grep 'gate=value-loop' "$BRAIN/audit-log.jsonl" 2>/dev/null | grep "sid=$SID" | tail -1)
PULLED_AFTER=$(jq -r '.pulled' "$STATE1")
AGENTS_AFTER=$(jq -r '.agents' "$STATE1")
TURN_AFTER=$(jq -r '.turn' "$STATE1")
[ "$PULLED_AFTER" = "$PULLED_BEFORE" ] || fail "telemetry watermark not independent of extraction marker: pulled grew from $PULLED_BEFORE to $PULLED_AFTER on an UNCHANGED transcript after the marker was deleted"
[ "$AGENTS_AFTER" = "$AGENTS_BEFORE" ] || fail "agents grew from $AGENTS_BEFORE to $AGENTS_AFTER on an unchanged transcript (marker-independence bug)"
[ "$TURN_AFTER" = "$TURN_BEFORE" ] || fail "turn grew from $TURN_BEFORE to $TURN_AFTER on an unchanged transcript (marker-independence bug)"
pass "telemetry's watermark is independent of the extraction marker (no double-count on marker-deleted retry)"

# --- Test 11: PreCompact advances the extraction marker with NO telemetry fold; ---
# stop-extract must still pick up everything after PreCompact via its own watermark.
SID6="telemetry-test-precompact"
WORKDIR6="$TMP/demo6"; mkdir -p "$WORKDIR6"
mkdir -p "$BRAIN/projects/demo6"
printf '# PROJECT: demo6\n\n## Goal\nprecompact demo\n' > "$BRAIN/projects/demo6/PROJECT.md"
MANIFEST6="$BRAIN/.injected-manifest-$SID6.jsonl"
cat > "$MANIFEST6" <<'EOF'
{"kind":"wiki","id":"old-learning"}
EOF
T6="$TMP/transcript6.jsonl"
cat > "$T6" <<EOF
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"x"}}]}}
EOF
printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$T6" "$WORKDIR6" "$SID6" \
  | env PATH="$STUB:$PATH" HOME="$TMP" BRAIN_DIR="$BRAIN" \
        CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" ANTHROPIC_API_KEY="" \
        bash "$ROOT/scripts/pre-compact.sh" >/dev/null 2>&1
# pre-compact.sh advances the extraction marker for demo6/SID6 but performs no
# telemetry fold. Append a Read of the manifested wiki page and run stop-extract —
# it must see the whole transcript via its own watermark (scanned_to still 0),
# not skip it because the extraction marker already covers those lines.
cat >> "$T6" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"$KNOW/wiki/learnings/old-learning.md"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
EOF
printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$T6" "$WORKDIR6" "$SID6" \
  | env PATH="$STUB:$PATH" HOME="$TMP" BRAIN_DIR="$BRAIN" \
        CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" ANTHROPIC_API_KEY="" \
        bash "$ROOT/scripts/stop-extract.sh" >/dev/null 2>&1
ROW11=$(grep 'gate=value-loop' "$BRAIN/audit-log.jsonl" 2>/dev/null | grep "sid=$SID6" | tail -1)
[ -n "$ROW11" ] || fail "PreCompact-then-Stop: no value-loop row for sid=$SID6 (PreCompact may have advanced the extraction marker AND been trusted by telemetry)"
echo "$ROW11" | grep -q 'read=1' || fail "PreCompact-then-Stop: read should be 1 (whole transcript scanned via telemetry's own watermark): $ROW11"
pass "stop-extract's telemetry watermark still scans a window PreCompact advanced the extraction marker past"

# --- Test 12: a present-but-unparseable state file is quarantined loudly, not ---
# silently reset to {} (all cumulative counters would otherwise zero with no trace).
SID7="telemetry-test-corruptstate"
WORKDIR7="$TMP/demo7"; mkdir -p "$WORKDIR7"
mkdir -p "$BRAIN/projects/demo7"
printf '# PROJECT: demo7\n\n## Goal\ncorrupt-state demo\n' > "$BRAIN/projects/demo7/PROJECT.md"
MANIFEST7="$BRAIN/.injected-manifest-$SID7.jsonl"
STATE7="$BRAIN/.value-loop-state-$SID7.json"
cat > "$MANIFEST7" <<'EOF'
{"kind":"wiki","id":"old-learning"}
EOF
printf '{"hit_ids":["demo"],"pulled":40,"agents":9,"tie' > "$STATE7"
T7="$TMP/transcript7.jsonl"
cat > "$T7" <<EOF
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"$KNOW/wiki/learnings/old-learning.md"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
EOF
rm -f "$BRAIN/error-log.jsonl"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$T7" "$WORKDIR7" "$SID7" \
  | env PATH="$STUB:$PATH" HOME="$TMP" BRAIN_DIR="$BRAIN" \
        CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" ANTHROPIC_API_KEY="" \
        bash "$ROOT/scripts/stop-extract.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] || fail "stop-extract (corrupt state file) non-zero exit ($RC)"
grep -q 'value-loop state' "$BRAIN/error-log.jsonl" 2>/dev/null || fail "corrupt state file: no error-log entry for the quarantine"
[ -f "$STATE7.corrupt" ] || fail "corrupt state file: $STATE7.corrupt was not created (torn file not quarantined)"
pass "a present-but-unparseable value-loop state file is quarantined loudly (error-log entry + .corrupt file)"

# --- Test 13: the value-loop pass runs even with NO injection manifest at all ---
# (a fresh project before the first successful injection). Gating on manifest
# FILE EXISTENCE lost pulled/agents/tiers/turn for every pre-injection Stop.
SID8="telemetry-test-nomanifest"
WORKDIR8="$TMP/demo8"; mkdir -p "$WORKDIR8"
mkdir -p "$BRAIN/projects/demo8"
printf '# PROJECT: demo8\n\n## Goal\nno-manifest demo\n' > "$BRAIN/projects/demo8/PROJECT.md"
rm -f "$BRAIN/.injected-manifest-$SID8.jsonl"
T8="$TMP/transcript8.jsonl"
cat > "$T8" <<EOF
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent","input":{"model":"haiku","subagent_type":"fork"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"mcp__plugin_second-brain_knowledge-base__knowledge_search","input":{"query":"x"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
EOF
printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$T8" "$WORKDIR8" "$SID8" \
  | env PATH="$STUB:$PATH" HOME="$TMP" BRAIN_DIR="$BRAIN" \
        CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" ANTHROPIC_API_KEY="" \
        bash "$ROOT/scripts/stop-extract.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] || fail "stop-extract (no manifest) non-zero exit ($RC)"
ROW13=$(grep 'gate=value-loop' "$BRAIN/audit-log.jsonl" 2>/dev/null | grep "sid=$SID8" | tail -1)
[ -n "$ROW13" ] || fail "no-manifest session: value-loop row missing (gate wrongly required the manifest file to exist)"
echo "$ROW13" | grep -q 'injected=0' || fail "no-manifest session: injected should be 0: $ROW13"
echo "$ROW13" | grep -q 'agents=1' || fail "no-manifest session: agents should be 1: $ROW13"
echo "$ROW13" | grep -q 'pulled=1' || fail "no-manifest session: pulled should be 1: $ROW13"
echo "$ROW13" | grep -q 'tiers=haiku:1' || fail "no-manifest session: tiers should be haiku:1: $ROW13"
pass "value-loop pass runs even with no injection manifest (injected=0, real pulled/agents/tiers/turn still counted)"

# --- Test 14: a codemap hit id containing a space is %20-encoded in hits= so it ---
# doesn't break the documented single-space-delimited extraction pattern.
SID9="telemetry-test-spaceid"
WORKDIR9="$TMP/demo9"; mkdir -p "$WORKDIR9"
mkdir -p "$BRAIN/projects/demo9"
printf '# PROJECT: demo9\n\n## Goal\nspace-id demo\n' > "$BRAIN/projects/demo9/PROJECT.md"
MANIFEST9="$BRAIN/.injected-manifest-$SID9.jsonl"
printf '%s\n' '{"kind":"codemap","id":"src/my dir/x.ts"}' > "$MANIFEST9"
T9="$TMP/transcript9.jsonl"
cat > "$T9" <<EOF
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"C:\\\\repo\\\\src\\\\my dir\\\\x.ts"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
EOF
printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$T9" "$WORKDIR9" "$SID9" \
  | env PATH="$STUB:$PATH" HOME="$TMP" BRAIN_DIR="$BRAIN" \
        CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" ANTHROPIC_API_KEY="" \
        bash "$ROOT/scripts/stop-extract.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] || fail "stop-extract (space-id codemap hit) non-zero exit ($RC)"
grep -o 'hits=[^ ]*[[:space:]]ritual=' "$BRAIN/audit-log.jsonl" | grep -q "sid=$SID9" 2>/dev/null
ROW14=$(grep 'gate=value-loop' "$BRAIN/audit-log.jsonl" 2>/dev/null | grep "sid=$SID9" | tail -1)
[ -n "$ROW14" ] || fail "space-id codemap hit: value-loop row missing"
echo "$ROW14" | grep -oE 'hits=[^ ]*[[:space:]]ritual=' >/dev/null || fail "space-id codemap hit: the documented hits=...ritual= extraction pattern does not match (space leaked unencoded): $ROW14"
echo "$ROW14" | grep -q 'hits=src/my%20dir/x.ts' || fail "space-id codemap hit: expected %20-encoded hits value: $ROW14"
pass "a codemap hit id containing a space is %20-encoded in hits= (documented extraction pattern still matches)"

# --- Test 15: sb_manifest_add logs loudly (not silently) when the manifest append fails ---
SQUAT_SID="squat"
SQUAT_PATH="$BRAIN/.injected-manifest-$SQUAT_SID.jsonl"
mkdir -p "$SQUAT_PATH"
rm -f "$BRAIN/error-log.jsonl"
( source "$ROOT/scripts/lib.sh"; BRAIN_DIR="$BRAIN" SB_MANIFEST_SESSION_ID="$SQUAT_SID" sb_manifest_add wiki 'x' )
RC=$?
rmdir "$SQUAT_PATH" 2>/dev/null
[ "$RC" -eq 0 ] || fail "sb_manifest_add must stay fail-soft to the caller (exit 0) even on a write failure"
grep -q 'sb_manifest_add' "$BRAIN/error-log.jsonl" 2>/dev/null || fail "sb_manifest_add: an unwritable manifest must log to error-log.jsonl, not fail silently"
pass "sb_manifest_add logs loudly on a write failure while staying fail-soft to the caller"

# --- Test 16: an id that is BOTH the anchor AND a plain wiki/other id must not ---
# leak into injected/read/hits under its other kind — nonanchor excludes any id
# also manifested as the anchor from every non-anchor kind's accounting; only the
# anchor's own ritual accounting picks it up (real KB: a project slug can be both
# the ritual anchor AND a plain wiki page id).
SID10="telemetry-test-anchorcollision"
WORKDIR10="$TMP/demo10"; mkdir -p "$WORKDIR10"
mkdir -p "$BRAIN/projects/demo10"
printf '# PROJECT: demo10\n\n## Goal\nanchor collision demo\n' > "$BRAIN/projects/demo10/PROJECT.md"
MANIFEST10="$BRAIN/.injected-manifest-$SID10.jsonl"
cat > "$MANIFEST10" <<'EOF'
{"kind":"anchor","id":"demo"}
{"kind":"wiki","id":"demo"}
{"kind":"wiki","id":"other"}
EOF
T10="$TMP/transcript10.jsonl"
cat > "$T10" <<EOF
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"mcp__plugin_second-brain_knowledge-base__knowledge_neighbors","input":{"slug":"demo"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
EOF
printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$T10" "$WORKDIR10" "$SID10" \
  | env PATH="$STUB:$PATH" HOME="$TMP" BRAIN_DIR="$BRAIN" \
        CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" ANTHROPIC_API_KEY="" \
        bash "$ROOT/scripts/stop-extract.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] || fail "stop-extract (anchor/wiki id collision) non-zero exit ($RC)"
ROW16=$(grep 'gate=value-loop' "$BRAIN/audit-log.jsonl" 2>/dev/null | grep "sid=$SID10" | tail -1)
[ -n "$ROW16" ] || fail "anchor/wiki id collision: value-loop row missing"
echo "$ROW16" | grep -q 'injected=1' || fail "anchor/wiki id collision: injected should be 1 (only 'other'; the 'demo' wiki entry is excluded by nonanchor): $ROW16"
echo "$ROW16" | grep -q 'read=0' || fail "anchor/wiki id collision: read should be 0: $ROW16"
echo "$ROW16" | grep -q 'hits=none' || fail "anchor/wiki id collision: hits should be none: $ROW16"
echo "$ROW16" | grep -q 'ritual=1' || fail "anchor/wiki id collision: ritual should be 1 (the anchor fetch still counts): $ROW16"
pass "an id manifested as BOTH anchor and wiki is excluded from injected/read/hits, counted only as ritual"

# --- Test 17: cumulative cross-Stop merge — Stop 2's row must reflect BOTH ---
# windows' hits/agents/tiers/turn (the running per-session state), not just its
# own window (which would look like a rescan-from-zero).
SID11="telemetry-test-crossstopmerge"
WORKDIR11="$TMP/demo11"; mkdir -p "$WORKDIR11"
mkdir -p "$BRAIN/projects/demo11"
printf '# PROJECT: demo11\n\n## Goal\ncross-stop merge demo\n' > "$BRAIN/projects/demo11/PROJECT.md"
MANIFEST11="$BRAIN/.injected-manifest-$SID11.jsonl"
cat > "$MANIFEST11" <<'EOF'
{"kind":"anchor","id":"demo"}
{"kind":"wiki","id":"a"}
{"kind":"wiki","id":"b"}
EOF
T11="$TMP/transcript11.jsonl"
cat > "$T11" <<EOF
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"mcp__plugin_second-brain_knowledge-base__knowledge_search","input":{"query":"x"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent","input":{"model":"sonnet","subagent_type":"fork"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"mcp__plugin_second-brain_knowledge-base__knowledge_fetch","input":{"slug":"a"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
EOF
printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$T11" "$WORKDIR11" "$SID11" \
  | env PATH="$STUB:$PATH" HOME="$TMP" BRAIN_DIR="$BRAIN" \
        CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" ANTHROPIC_API_KEY="" \
        bash "$ROOT/scripts/stop-extract.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] || fail "stop-extract (cross-stop merge, Stop 1) non-zero exit ($RC)"
ROW17A=$(grep 'gate=value-loop' "$BRAIN/audit-log.jsonl" 2>/dev/null | grep "sid=$SID11" | tail -1)
[ -n "$ROW17A" ] || fail "cross-stop merge: Stop-1 value-loop row missing"
echo "$ROW17A" | grep -q 'read=1' || fail "cross-stop merge: Stop-1 read should be 1 (fetch of 'a'): $ROW17A"
echo "$ROW17A" | grep -q 'agents=1' || fail "cross-stop merge: Stop-1 agents should be 1: $ROW17A"
echo "$ROW17A" | grep -q 'turn=1' || fail "cross-stop merge: Stop-1 turn should be 1: $ROW17A"

cat >> "$T11" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"fork"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"mcp__plugin_second-brain_knowledge-base__knowledge_fetch","input":{"slug":"b"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"mcp__plugin_second-brain_knowledge-base__knowledge_neighbors","input":{"slug":"demo"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"more"}]}}
EOF
printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$T11" "$WORKDIR11" "$SID11" \
  | env PATH="$STUB:$PATH" HOME="$TMP" BRAIN_DIR="$BRAIN" \
        CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOW" ANTHROPIC_API_KEY="" \
        bash "$ROOT/scripts/stop-extract.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] || fail "stop-extract (cross-stop merge, Stop 2) non-zero exit ($RC)"
ROW17B=$(grep 'gate=value-loop' "$BRAIN/audit-log.jsonl" 2>/dev/null | grep "sid=$SID11" | tail -1)
[ -n "$ROW17B" ] || fail "cross-stop merge: Stop-2 value-loop row missing"
echo "$ROW17B" | grep -q 'read=2' || fail "cross-stop merge: Stop-2 read should be 2 (cumulative 'a'+'b'): $ROW17B"
echo "$ROW17B" | grep -qE 'hits=[^ ]*a' || fail "cross-stop merge: Stop-2 hits should contain 'a': $ROW17B"
echo "$ROW17B" | grep -qE 'hits=[^ ]*b' || fail "cross-stop merge: Stop-2 hits should contain 'b': $ROW17B"
echo "$ROW17B" | grep -q 'ritual=1' || fail "cross-stop merge: Stop-2 ritual should be 1: $ROW17B"
echo "$ROW17B" | grep -q 'pulled=1' || fail "cross-stop merge: Stop-2 pulled should be 1 (only Stop-1's knowledge_search — fetches of injected ids and the anchor call are excluded): $ROW17B"
echo "$ROW17B" | grep -q 'agents=2' || fail "cross-stop merge: Stop-2 agents should be 2 (cumulative, one per Stop): $ROW17B"
echo "$ROW17B" | grep -qE 'tiers=[^ ]*sonnet:1' || fail "cross-stop merge: Stop-2 tiers should contain sonnet:1: $ROW17B"
echo "$ROW17B" | grep -qE 'tiers=[^ ]*unset:1' || fail "cross-stop merge: Stop-2 tiers should contain unset:1: $ROW17B"
echo "$ROW17B" | grep -q 'turn=2' || fail "cross-stop merge: Stop-2 turn should be 2: $ROW17B"
[ "$ROW17A" != "$ROW17B" ] || fail "cross-stop merge: Stop-2 row identical to Stop-1 (no new row emitted)"
pass "cross-Stop merge: Stop-1 read=1/agents=1/turn=1, Stop-2 read=2/hits=a,b/ritual=1/pulled=1/agents=2/tiers=sonnet:1,unset:1/turn=2 (cumulative merge, not a rescan)"

echo; echo "ALL PASS"
