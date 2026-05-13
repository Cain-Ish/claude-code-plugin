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

echo "ALL PASS"
