#!/bin/bash
# Tests for the pushed sessions digest (P0 rec 4, capture widening).
# Contract under test:
#   1. lib.sh:sb_append_session_digest — one compact JSONL line per SESSION in
#      $BRAIN_DIR/sessions-digest.jsonl {ts, slug, session_id, goal, outcome};
#      the Stop hook fires per TURN, so a same-session append REPLACES the prior
#      entry (latest wins); capped per slug (default 15, oldest dropped); a
#      both-empty goal+outcome is a no-write; newlines folded; corrupt lines
#      tolerated (dropped, never fatal).
#   2. stop-extract.sh appends the digest entry after a successful extraction
#      (end-to-end with a stubbed `claude`).
#   3. session-load.sh renders the last N entries for THIS slug as a
#      "[Recent sessions" block (newest first), under a bounded slice, with
#      kill switch SB_SESSIONS_DIGEST=off, and never leaks other slugs.
#   4. Wiring locks: pre-compact.sh and lib.sh:sb_extract_transcript (drainer
#      path) call the helper — prose promises get machine locks.
unset CLAUDECODE
set -u
PLUGIN_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# ============================================================================
# 1. sb_append_session_digest unit behavior (sourced lib.sh, sandbox BRAIN_DIR)
# ============================================================================
export HOME="$TMP/home"; mkdir -p "$HOME"
export BRAIN_DIR="$TMP/brain"; mkdir -p "$BRAIN_DIR"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib.sh" || fail "lib.sh failed to source"
DIGEST="$BRAIN_DIR/sessions-digest.jsonl"

sb_append_session_digest "proj-a" "sid-1" "ship the widget (reached: implement)" "partial: core landed" \
  || fail "append: helper returned non-zero"
[ -f "$DIGEST" ] || fail "append: digest file not created"
N=$(wc -l < "$DIGEST" | tr -d ' ')
[ "$N" -eq 1 ] || fail "append: expected 1 line, got $N"
jq -e 'select(.slug=="proj-a" and .session_id=="sid-1"
       and .goal=="ship the widget (reached: implement)"
       and .outcome=="partial: core landed"
       and (.ts | test("^20[0-9]{2}-")))' "$DIGEST" >/dev/null 2>&1 \
  || fail "append: record fields wrong: $(cat "$DIGEST")"
pass "helper: appends one compact record with ts/slug/session_id/goal/outcome"

# Same-session re-append REPLACES (Stop fires per turn — no duplicate sessions).
sb_append_session_digest "proj-a" "sid-1" "ship the widget (reached: verify)" "done: widget shipped"
N=$(wc -l < "$DIGEST" | tr -d ' ')
[ "$N" -eq 1 ] || fail "replace: expected 1 line after same-session append, got $N"
grep -qF 'done: widget shipped' "$DIGEST" || fail "replace: latest outcome did not win"
grep -qF 'partial: core landed' "$DIGEST" && fail "replace: stale same-session entry survived"
pass "helper: same session_id replaces in place (latest wins)"

# Both-empty goal+outcome → no write, file untouched.
BEFORE=$(cat "$DIGEST")
sb_append_session_digest "proj-a" "sid-empty" "" ""
AFTER=$(cat "$DIGEST")
[ "$BEFORE" = "$AFTER" ] || fail "empty: both-empty goal+outcome must be a no-write"
pass "helper: both-empty goal+outcome is a no-write"

# Newlines in goal are folded to spaces (the render is line-oriented).
sb_append_session_digest "proj-a" "sid-nl" "$(printf 'line one\nline two')" "done"
jq -e 'select(.session_id=="sid-nl") | select(.goal | test("line one line two"))' "$DIGEST" >/dev/null 2>&1 \
  || fail "newline-fold: goal newlines not folded: $(grep sid-nl "$DIGEST")"
N=$(wc -l < "$DIGEST" | tr -d ' ')
[ "$N" -eq 2 ] || fail "newline-fold: record count wrong (got $N)"
pass "helper: newlines in goal folded to spaces"

# Per-slug cap: 17 distinct sessions for proj-b → 15 newest kept; proj-a intact.
i=1
while [ "$i" -le 17 ]; do
  sb_append_session_digest "proj-b" "b-sid-$i" "goal $i" "done: $i"
  i=$((i+1))
done
NB=$(jq -s '[.[] | select(.slug=="proj-b")] | length' "$DIGEST")
[ "$NB" -eq 15 ] || fail "cap: expected 15 proj-b entries, got $NB"
grep -qF '"b-sid-1"' "$DIGEST" && fail "cap: oldest proj-b entry survived the cap"
grep -qF '"b-sid-17"' "$DIGEST" || fail "cap: newest proj-b entry missing"
NA=$(jq -s '[.[] | select(.slug=="proj-a")] | length' "$DIGEST")
[ "$NA" -eq 2 ] || fail "cap: proj-a entries damaged by proj-b cap (got $NA)"
pass "helper: per-slug cap 15 (oldest dropped, other slugs untouched)"

# Corrupt line tolerated: dropped on next append, append still lands.
printf 'not json at all\n' >> "$DIGEST"
sb_append_session_digest "proj-a" "sid-after-corrupt" "post-corruption goal" "done"
grep -qF 'not json at all' "$DIGEST" && fail "corrupt: garbage line survived the rewrite"
grep -qF 'post-corruption goal' "$DIGEST" || fail "corrupt: append after corrupt line failed"
jq -s 'length' "$DIGEST" >/dev/null 2>&1 || fail "corrupt: digest no longer parseable"
pass "helper: corrupt lines dropped, appends keep landing"

# ============================================================================
# 2. stop-extract.sh end-to-end: extraction delta → digest entry
# ============================================================================
SANDBOX="$TMP/e2e"
mkdir -p "$SANDBOX/.second-brain/projects/test-slug" "$SANDBOX/knowledge/wiki" \
         "$SANDBOX/repo/test-slug" "$SANDBOX/path-stub" "$SANDBOX/transcript"
cat > "$SANDBOX/.second-brain/projects/test-slug/PROJECT.md" <<'EOF'
# PROJECT: test-slug

## Goal
seeded.

## State

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: 2026-05-01T00:00:00Z -->
EOF
cat > "$SANDBOX/transcript/session.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/foo.ts","old_string":"a","new_string":"b"}}]}}
EOF
cat > "$SANDBOX/path-stub/claude" <<'EOF'
#!/bin/bash
cat <<'JSON'
{"recent_decisions":[],"open_blockers":[],"cross_refs":[],"files_touched":[],"session_goal":"widen capture (reached: verify)","session_outcome":"done: schema widened and tested"}
JSON
EOF
chmod +x "$SANDBOX/path-stub/claude"
jq -nc --arg sid "e2e-session" --arg tp "$SANDBOX/transcript/session.jsonl" \
      --arg cwd "$SANDBOX/repo/test-slug" \
  '{session_id:$sid, transcript_path:$tp, cwd:$cwd, hook_event_name:"Stop"}' \
  | env HOME="$SANDBOX" BRAIN_DIR="$SANDBOX/.second-brain" PATH="$SANDBOX/path-stub:$PATH" \
        ANTHROPIC_API_KEY="" bash "$PLUGIN_ROOT/scripts/stop-extract.sh" >/dev/null 2>&1
E2E_DIGEST="$SANDBOX/.second-brain/sessions-digest.jsonl"
[ -f "$E2E_DIGEST" ] || fail "e2e: stop-extract did not create sessions-digest.jsonl"
jq -e 'select(.slug=="test-slug" and .session_id=="e2e-session"
       and .goal=="widen capture (reached: verify)"
       and .outcome=="done: schema widened and tested")' "$E2E_DIGEST" >/dev/null 2>&1 \
  || fail "e2e: digest entry wrong: $(cat "$E2E_DIGEST")"
pass "stop-extract: successful extraction appends the digest entry"

# ============================================================================
# 3. session-load.sh render: pushed continuity block
# ============================================================================
LOAD="$PLUGIN_ROOT/scripts/session-load.sh"
RSANDBOX="$TMP/render"
RBRAIN="$RSANDBOX/.second-brain"
RPROJ="$RSANDBOX/work/render-proj"
mkdir -p "$RBRAIN/projects/render-proj" "$RPROJ"
cat > "$RBRAIN/projects/render-proj/PROJECT.md" <<'EOF'
# PROJECT: render-proj
## Goal
seeded.
EOF
# 7 entries for render-proj (only the newest 5 should render) + 1 foreign slug.
{
  i=1
  while [ "$i" -le 7 ]; do
    printf '{"ts":"2026-07-%02dT00:00:00Z","slug":"render-proj","session_id":"r-%s","goal":"goal number %s","outcome":"done: thing %s"}\n' "$i" "$i" "$i" "$i"
    i=$((i+1))
  done
  printf '{"ts":"2026-07-30T00:00:00Z","slug":"other-proj","session_id":"x-1","goal":"FOREIGN GOAL MUST NOT LEAK","outcome":"done"}\n'
} > "$RBRAIN/sessions-digest.jsonl"
STUB="$TMP/rstub"; mkdir -p "$STUB"; printf '#!/bin/bash\nexit 0\n' > "$STUB/claude"; chmod +x "$STUB/claude"
run_load() {
  printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$RPROJ" \
    | env PATH="$STUB:$PATH" HOME="$RSANDBOX" BRAIN_DIR="$RBRAIN" \
          CLAUDE_PROJECT_DIR="$RPROJ" ANTHROPIC_API_KEY="" ${1:-} \
          bash "$LOAD" 2>/dev/null
}
OUT=$(run_load)
printf '%s' "$OUT" | grep -q '\[Recent sessions' \
  || fail "render: digest block header missing (got: $OUT)"
printf '%s' "$OUT" | grep -qF 'goal number 7' || fail "render: newest entry missing"
printf '%s' "$OUT" | grep -qF 'done: thing 7' || fail "render: outcome not rendered"
printf '%s' "$OUT" | grep -qF 'goal number 3' || fail "render: 5th-newest entry missing (window too small)"
printf '%s' "$OUT" | grep -qF 'goal number 2' && fail "render: 6th-newest entry rendered (cap 5 broken)"
printf '%s' "$OUT" | grep -qF 'FOREIGN GOAL MUST NOT LEAK' \
  && fail "render: another project's digest entry leaked into this session"
# Newest first: line for goal 7 appears before line for goal 6.
L7=$(printf '%s\n' "$OUT" | grep -nF 'goal number 7' | head -1 | cut -d: -f1)
L6=$(printf '%s\n' "$OUT" | grep -nF 'goal number 6' | head -1 | cut -d: -f1)
[ -n "$L7" ] && [ -n "$L6" ] && [ "$L7" -lt "$L6" ] || fail "render: entries not newest-first (7@$L7 vs 6@$L6)"
pass "session-load: renders last 5 for THIS slug, newest first, no cross-project leak"

OUT_OFF=$(run_load "SB_SESSIONS_DIGEST=off")
printf '%s' "$OUT_OFF" | grep -q '\[Recent sessions' \
  && fail "kill switch: SB_SESSIONS_DIGEST=off did not suppress the block"
pass "session-load: SB_SESSIONS_DIGEST=off suppresses the block"

# Absent digest file → no block, no error.
rm -f "$RBRAIN/sessions-digest.jsonl"
OUT_NONE=$(run_load)
printf '%s' "$OUT_NONE" | grep -q '\[Recent sessions' \
  && fail "absent-file: block rendered with no digest file"
pass "session-load: absent digest file is a silent no-op"

# ============================================================================
# 3b. Drainer guards (adversarial-review fixes, live-reproduced pre-fix):
# a SUBAGENT archive carries the PARENT session's id — draining it must NOT
# replace the session's real digest entry; a headerless archive must NOT
# collapse onto a shared "unknown" key.
# ============================================================================
GBRAIN="$TMP/guard-brain"
mkdir -p "$GBRAIN/projects"
BRAIN_DIR="$GBRAIN"
GDIGEST="$GBRAIN/sessions-digest.jsonl"
# Seed the session's REAL continuity line.
sb_append_session_digest "guard-slug" "parent-sid" "the real goal" "done: the real outcome"
# A subagent-result archive with the SAME (parent) session id.
GSUB="$TMP/sub-agent1_guard-slug_2026-07-30.txt"
cat > "$GSUB" <<'EOF'
--- session-meta ---
session_id: parent-sid
project_slug: guard-slug
agent_type: general-purpose
agent_id: agent1
date: 2026-07-30
tool_count: 5
subagent_result: true
---

ASSISTANT:
subagent result body
EOF
sb_call_extractor() { printf '{"recent_decisions":[],"session_goal":"SUBAGENT-DERIVED GOAL","session_outcome":"done: subagent noise"}' > "$2"; return 0; }
sb_extract_transcript "$GSUB" "guard-slug" >/dev/null 2>&1 || fail "guard-sub: extraction failed"
grep -qF 'the real goal' "$GDIGEST" || fail "guard-sub: real digest entry was lost"
grep -qF 'SUBAGENT-DERIVED GOAL' "$GDIGEST" && fail "guard-sub: subagent extraction REPLACED the session's digest entry"
pass "drainer: subagent archive never touches the parent session's digest entry"
# Headerless archive (no session_id) → no digest write at all.
GNOHDR="$TMP/nohdr_guard-slug_2026-07-30.txt"
printf -- '--- session-meta ---\nproject_slug: guard-slug\n---\n\nUSER: x\nASSISTANT: y\n' > "$GNOHDR"
BEFORE=$(cat "$GDIGEST")
sb_extract_transcript "$GNOHDR" "guard-slug" >/dev/null 2>&1 || fail "guard-nohdr: extraction failed"
AFTER=$(cat "$GDIGEST")
[ "$BEFORE" = "$AFTER" ] || fail "guard-nohdr: headerless archive wrote a digest entry (unknown-key collision class)"
pass "drainer: archive without session_id writes no digest line (no unknown-key collisions)"
unset -f sb_call_extractor

# ============================================================================
# 4. Wiring locks: every extraction path calls the helper
# ============================================================================
grep -q 'sb_append_session_digest' "$PLUGIN_ROOT/scripts/stop-extract.sh" \
  || fail "wiring: stop-extract.sh does not call sb_append_session_digest"
grep -q 'sb_append_session_digest' "$PLUGIN_ROOT/scripts/pre-compact.sh" \
  || fail "wiring: pre-compact.sh does not call sb_append_session_digest"
awk '/^sb_extract_transcript\(\)/,/^}/' "$PLUGIN_ROOT/scripts/lib.sh" | grep -q 'sb_append_session_digest' \
  || fail "wiring: drainer path (lib.sh sb_extract_transcript) does not call sb_append_session_digest"
pass "wiring: all three extraction paths call sb_append_session_digest"

echo
echo "ALL PASS"
