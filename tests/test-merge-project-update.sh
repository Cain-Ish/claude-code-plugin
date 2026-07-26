#!/bin/bash
# Tests for scripts/merge-project-update.sh.
# Contract: reads JSON delta on stdin (or --json-file), idempotently merges
# into the target PROJECT.md sections, scaffolds wiki pages for missing
# [[refs]] in ~/knowledge/wiki/entities/, updates last_updated. Always exits 0
# unless given an unparseable PROJECT.md or invalid JSON.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/merge-project-update.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export BRAIN_DIR="$TMP/brain"; mkdir -p "$TMP/brain"  # isolate the main body's sb_inc_wiki_writes from the real ~/.second-brain (T8/T9 below override with their own sandboxes)
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

seed_project() {
  local f="$1"
  cat > "$f" <<'EOF'
# PROJECT: test-slug

## Goal
test goal.

## State
unchanged.

## Conventions
- conv 1
- conv 2

## Recent decisions
- [decision] picked X over Y

## Open blockers
- [active] blocker A

## Cross-references
- [[existing-ref]]

<!-- last_updated: 2026-05-01T00:00:00Z -->
<!-- last_queried_wiki: -->
EOF
}

# --- Test 1: append new decisions, dedupe against existing, cap 5, date-prefixed.
PROJ="$TMP/p1.md"; WIKI="$TMP/wiki1"; mkdir -p "$WIKI"
seed_project "$PROJ"
jq -nc '{
  recent_decisions: ["picked X over Y", "use Haiku for extraction", "wiki at second-brain/wiki/"],
  open_blockers: [],
  cross_refs: [],
  files_touched: []
}' | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI">/dev/null 2>&1 || fail "decision-merge: script exited non-zero"

COUNT=$(grep -c "picked X over Y" "$PROJ" || true)
[ "$COUNT" -eq 1 ] || fail "decision-merge: expected 1 'picked X over Y' line, got $COUNT"
DEC_COUNT=$(awk '/^## Recent decisions$/{flag=1; next} /^## /{flag=0} flag && /^- /' "$PROJ" | wc -l | tr -d ' ')
[ "$DEC_COUNT" -le 5 ] || fail "decision-merge: cap exceeded ($DEC_COUNT > 5)"
[ "$DEC_COUNT" -eq 3 ] || fail "decision-merge: expected exactly 3 bullets (1 existing + 2 new), got $DEC_COUNT"
grep -q "use Haiku" "$PROJ" || fail "decision-merge: new decision 'use Haiku' missing"
# New decisions should be date-prefixed
grep -qE '\[20[0-9]{2}-[0-9]{2}-[0-9]{2}\] use Haiku' "$PROJ" || fail "decision-merge: new decision not date-prefixed"
pass "decisions: dedupe + cap 5 + date-prefixed + append new"

# --- Test 2: blockers append, cap 15.
PROJ="$TMP/p2.md"; WIKI="$TMP/wiki2"; mkdir -p "$WIKI"
seed_project "$PROJ"
NEW_BLOCKERS=$(jq -nc '[range(20) | "[active] blocker \(.)"]')
jq -nc --argjson b "$NEW_BLOCKERS" '{
  recent_decisions: [],
  open_blockers: $b,
  cross_refs: [],
  files_touched: []
}' | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI">/dev/null 2>&1 || fail "blocker-merge: script exited non-zero"
B_COUNT=$(awk '/^## Open blockers$/{flag=1; next} /^## /{flag=0} flag && /^- /' "$PROJ" | wc -l | tr -d ' ')
[ "$B_COUNT" -le 15 ] || fail "blocker-merge: cap exceeded ($B_COUNT > 15)"
[ "$B_COUNT" -ge 2 ] || fail "blocker-merge: expected merge to add blockers (got $B_COUNT)"
pass "blockers: cap 15"

# --- Test 3: cross-refs scaffold wiki page for missing, leave existing untouched.
PROJ="$TMP/p3.md"; WIKI="$TMP/wiki3"; mkdir -p "$WIKI/wiki/entities"
seed_project "$PROJ"
echo "# pre-existing wiki page" > "$WIKI/wiki/entities/existing-ref.md"
jq -nc '{
  recent_decisions: [],
  open_blockers: [],
  cross_refs: ["existing-ref", "new-ref-from-session"],
  files_touched: []
}' | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI" >/dev/null 2>&1 || fail "wiki-stub: script exited non-zero"
[ -f "$WIKI/wiki/entities/existing-ref.md" ] || fail "wiki-stub: existing wiki file disappeared"
grep -q "pre-existing wiki page" "$WIKI/wiki/entities/existing-ref.md" || fail "wiki-stub: existing wiki content was overwritten"
[ -f "$WIKI/wiki/entities/new-ref-from-session.md" ] || fail "wiki-stub: new-ref page was not created"
grep -q 'type: entities' "$WIKI/wiki/entities/new-ref-from-session.md" || fail "wiki-stub: new page missing frontmatter"
grep -q "\[\[new-ref-from-session\]\]" "$PROJ" || fail "wiki-stub: cross-ref bullet not added to PROJECT.md"
pass "cross-refs: proper wiki page creation + leaves existing alone"

# --- Test 4: last_updated footer is bumped to a current ISO timestamp.
PROJ="$TMP/p4.md"; WIKI="$TMP/wiki4"; mkdir -p "$WIKI"
seed_project "$PROJ"
jq -nc '{
  recent_decisions: ["mini change"],
  open_blockers: [], cross_refs: [], files_touched: []
}' | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI">/dev/null 2>&1 || fail "timestamp: script exited non-zero"
grep -q "<!-- last_updated: 2026-05-01T00:00:00Z -->" "$PROJ" && fail "timestamp: footer not bumped"
grep -qE "<!-- last_updated: 20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z -->" "$PROJ" || fail "timestamp: new footer missing or malformed"
pass "last_updated: bumped to ISO timestamp"

# --- Test 5: empty deltas → no-op (no error, last_updated NOT bumped).
PROJ="$TMP/p5.md"; WIKI="$TMP/wiki5"; mkdir -p "$WIKI"
seed_project "$PROJ"
ORIG_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
jq -nc '{recent_decisions: [], open_blockers: [], cross_refs: [], files_touched: []}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI">/dev/null 2>&1 || fail "empty-delta: script exited non-zero"
NEW_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
[ "$ORIG_HASH" = "$NEW_HASH" ] || fail "empty-delta: PROJECT.md mutated despite empty input"
pass "empty deltas: idempotent no-op"

# --- Test 6: invalid JSON on stdin → exit non-zero, PROJECT.md untouched.
PROJ="$TMP/p6.md"; WIKI="$TMP/wiki6"; mkdir -p "$WIKI"
seed_project "$PROJ"
ORIG_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
printf 'not json' | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI">/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] || fail "invalid-json: expected non-zero exit"
NEW_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
[ "$ORIG_HASH" = "$NEW_HASH" ] || fail "invalid-json: PROJECT.md mutated on bad input"
pass "invalid JSON: rejects loudly, leaves PROJECT.md untouched"

# --- Test 7: dedupe is case-insensitive on cross_refs.
PROJ="$TMP/p7.md"; WIKI="$TMP/wiki7"; mkdir -p "$WIKI"
seed_project "$PROJ"
jq -nc '{
  recent_decisions: [], open_blockers: [],
  cross_refs: ["Existing-Ref", "EXISTING-REF"],
  files_touched: []
}' | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI">/dev/null 2>&1 || fail "case-dedupe: script exited non-zero"
DUP=$(grep -ci 'existing-ref' "$PROJ" || true)
[ "$DUP" -eq 1 ] || fail "case-dedupe: expected 1 existing-ref reference, got $DUP"
pass "cross-refs: case-insensitive dedupe"

# --- Test: counter increments when a wiki page is written ---------------
# sb_inc_wiki_writes writes to $BRAIN_DIR/projects/<slug>/.wiki-writes
# Redirect HOME and BRAIN_DIR to a per-test sandbox so no real ~/.second-brain
# directories are created (matches init_sandbox pattern in test-maintainer-auto-dispatch.sh).
T8_SLUG="test-slug-ctr"
export HOME="$TMP/sandbox-t8"
export BRAIN_DIR="$HOME/.second-brain"
WIKI8="$TMP/wiki8"; mkdir -p "$WIKI8"
T8_PROJ_DIR="$TMP/sandbox-t8-proj/$T8_SLUG"
mkdir -p "$T8_PROJ_DIR"
T8_PM="$T8_PROJ_DIR/PROJECT.md"
seed_project "$T8_PM"
T8_COUNTER="$BRAIN_DIR/projects/$T8_SLUG/.wiki-writes"
# cross_refs with a new page name → triggers wiki write → WIKI_WRITES=1
jq -nc '{
  recent_decisions: [],
  open_blockers: [],
  cross_refs: ["new-page-ctr-test"],
  files_touched: []
}' | "$SCRIPT" --project-md "$T8_PM" --knowledge-dir "$WIKI8" >/dev/null 2>&1
T8_COUNT=$(cat "$T8_COUNTER" 2>/dev/null || echo 0)
[ "$T8_COUNT" = "1" ] || fail "counter-wiki-write: expected counter=1, got $T8_COUNT"
pass "merge increments .wiki-writes on wiki page write"
unset HOME BRAIN_DIR

# --- Test: counter unchanged when no wiki write happens -----------------
T9_SLUG="test-slug-noctr"
export HOME="$TMP/sandbox-t9"
export BRAIN_DIR="$HOME/.second-brain"
WIKI9="$TMP/wiki9"; mkdir -p "$WIKI9"
T9_PROJ_DIR="$TMP/sandbox-t9-proj/$T9_SLUG"
mkdir -p "$T9_PROJ_DIR"
T9_PM="$T9_PROJ_DIR/PROJECT.md"
seed_project "$T9_PM"
T9_COUNTER="$BRAIN_DIR/projects/$T9_SLUG/.wiki-writes"
# Empty delta — no cross_refs, no wiki page touched, no WIKI_WRITES trigger
jq -nc '{
  recent_decisions: [],
  open_blockers: [],
  cross_refs: [],
  files_touched: []
}' | "$SCRIPT" --project-md "$T9_PM" --knowledge-dir "$WIKI9" >/dev/null 2>&1
T9_EXISTS=0
[ -f "$T9_COUNTER" ] && T9_EXISTS=1
[ "$T9_EXISTS" -eq 0 ] || fail "counter-no-write: counter file should not exist on no-write run"
pass "merge leaves .wiki-writes alone on no-wiki-write run"
unset HOME BRAIN_DIR

# --- Test (MEDIUM): a plain wiki_updates CREATE (no ai_block) actually writes a
# real wiki page. No ai_block => the node/render path is skipped entirely, so this
# exercises the merge's page-authoring (frontmatter + content body) without needing
# the bundled node renderer — and asserts the EFFECT (file exists, frontmatter type,
# the content body landed verbatim), not just exit 0.
PROJ="$TMP/p10.md"; WIKI10="$TMP/wiki10"; mkdir -p "$WIKI10"
# T9 above ended with `unset HOME BRAIN_DIR`; restore both (HOME is referenced by
# merge-project-update.sh under set -u) to per-test sandboxes so nothing escapes.
export HOME="$TMP/sandbox-t10"; mkdir -p "$HOME"
export BRAIN_DIR="$TMP/brain"
seed_project "$PROJ"
jq -nc '{
  wiki_updates: [{
    category: "learnings",
    slug: "plain-create",
    action: "create",
    title: "T",
    description: "d",
    content: "REAL LEARNINGS BODY SENTINEL"
  }]
}' | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI10" >/dev/null 2>&1 || fail "wiki-create: script exited non-zero"
PAGE="$WIKI10/wiki/learnings/plain-create.md"
[ -f "$PAGE" ] || fail "wiki-create: page $PAGE was not created"
grep -q '^type: learnings$' "$PAGE" || fail "wiki-create: page missing 'type: learnings' frontmatter (got: $(cat "$PAGE"))"
grep -qF 'REAL LEARNINGS BODY SENTINEL' "$PAGE" || fail "wiki-create: content body sentinel missing from page (got: $(cat "$PAGE"))"
pass "wiki_updates create writes a real learnings page (node-less path)"

# --- Test: session_goal → deterministic one-line ## State note (replace-style) ---
PROJ="$TMP/p11.md"; WIKI11="$TMP/wiki11"; mkdir -p "$WIKI11"
seed_project "$PROJ"
jq -nc '{session_goal:"ship the intent spine (reached: verify)"}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI11" >/dev/null 2>&1 || fail "state-note: script exited non-zero"
grep -q '^last session goal: ship the intent spine (reached: verify)$' "$PROJ" \
  || fail "state-note: note line missing from PROJECT.md"
grep -q '^unchanged\.$' "$PROJ" || fail "state-note: pre-existing ## State content was clobbered"
awk '/^## State$/{f=1;next} /^## /{f=0} f' "$PROJ" | grep -q '^last session goal:' \
  || fail "state-note: note did not land inside ## State"
# A later session REPLACES the note — never accumulates.
jq -nc '{session_goal:"harden the drift gate (reached: implement)"}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI11" >/dev/null 2>&1
N=$(grep -c '^last session goal:' "$PROJ" || true)
[ "$N" -eq 1 ] || fail "state-note: expected exactly 1 note line after replace, got $N"
grep -q 'harden the drift gate (reached: implement)' "$PROJ" || fail "state-note: replace did not update the note"
pass "session_goal: one-line ## State note, replace-style, preserves other State content"

# --- Test: empty session_goal is a no-op (note survives, nothing churns) ---
ORIG_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
jq -nc '{session_goal:""}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI11" >/dev/null 2>&1 || fail "state-empty: script exited non-zero"
NEW_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
[ "$ORIG_HASH" = "$NEW_HASH" ] || fail "state-empty: empty session_goal must be a no-op (file changed)"
pass "session_goal: empty emission never wipes the note or bumps last_updated"

# --- Test: PROJECT.md WITHOUT a ## State heading → section appended, not dropped ---
PROJ="$TMP/p12.md"; WIKI12="$TMP/wiki12"; mkdir -p "$WIKI12"
cat > "$PROJ" <<'EOF'
# PROJECT: no-state-slug

## Goal
hand-rolled file.

## Recent decisions

<!-- last_updated: 2026-05-01T00:00:00Z -->
EOF
jq -nc '{session_goal:"resume without a State section (reached: plan)"}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI12" >/dev/null 2>&1 || fail "state-append: script exited non-zero"
grep -q '^## State$' "$PROJ" || fail "state-append: missing heading should be appended"
grep -q '^last session goal: resume without a State section (reached: plan)$' "$PROJ" \
  || fail "state-append: note missing after heading append"
# Second merge now finds the heading and replaces in place (still exactly one note).
jq -nc '{session_goal:"second pass (reached: implement)"}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI12" >/dev/null 2>&1
N=$(grep -c '^last session goal:' "$PROJ" || true)
[ "$N" -eq 1 ] || fail "state-append: expected exactly 1 note after replace, got $N"
N=$(grep -c '^## State$' "$PROJ" || true)
[ "$N" -eq 1 ] || fail "state-append: heading duplicated on second merge"
pass "session_goal: missing ## State heading appended once, then replaced in place"

echo "ALL PASS"
