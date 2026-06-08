#!/bin/bash
# PR2 (focus-tracking): forward-looking ## Plan block in PROJECT.md, [pinned] protection,
# and the merge-side reconcile. The plan is a checkbox ledger the Stop hook rewrites each
# session; [pinned] lines are human-authored and never rotated or replaced.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
MERGE="$ROOT/scripts/merge-project-update.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export BRAIN_DIR="$TMP/brain"; mkdir -p "$TMP/brain"  # isolate sb_inc_wiki_writes from the real ~/.second-brain
WIKI="$TMP/wiki"; mkdir -p "$WIKI"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

seed() {
  cat > "$1" <<'EOF'
# PROJECT: test-slug

## Goal
g.

## State

## Plan
- [ ] old step one
- [x] old done
- [pinned] human-authored north star

## Conventions

## Recent decisions
- [decision] d1

## Open blockers

## Cross-references

<!-- last_updated: 2026-05-01T00:00:00Z -->
<!-- last_queried_wiki: -->
EOF
}

# 1. Template parity: all three PROJECT.md scaffolds carry ## Plan
for f in scripts/lib.sh scripts/stop-extract.sh scripts/session-load.sh; do
  grep -q '^## Plan$' "$ROOT/$f" || fail "$f template missing ## Plan"
done
pass "all 3 PROJECT.md templates include ## Plan"

# 2. replace-reconcile: emitted items replace non-pinned, [pinned] preserved
P="$TMP/p1.md"; seed "$P"
printf '%s' '{"plan":["[ ] new step A","[x] shipped B"]}' | bash "$MERGE" --project-md "$P" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -q '^- \[pinned\] human-authored north star$' "$P" || fail "pinned plan line not preserved"
grep -q 'new step A' "$P" || fail "new plan item not written"
grep -q 'old step one' "$P" && fail "old non-pinned plan item not replaced"
pass "plan replace-reconcile preserves [pinned], replaces non-pinned"

# 3. checkbox normalization
grep -qE '^- \[ \] new step A$' "$P" || fail "open item not normalized to - [ ]"
grep -qE '^- \[x\] shipped B$' "$P" || fail "done item not normalized to - [x]"
pass "plan items normalized to checkbox form"

# 4. no-wipe on empty/absent plan delta (a degraded run must never erase the plan)
P2="$TMP/p2.md"; seed "$P2"
printf '%s' '{"recent_decisions":["[decision] d2"]}' | bash "$MERGE" --project-md "$P2" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -q 'old step one' "$P2" || fail "empty plan delta wiped the existing plan"
grep -q '^- \[pinned\] human-authored north star$' "$P2" || fail "empty plan delta dropped pinned line"
pass "empty/absent plan delta leaves the plan untouched"

# 5. non-pinned plan capped at 7; pinned preserved
P3="$TMP/p3.md"; seed "$P3"
printf '%s' '{"plan":["[ ] s1","[ ] s2","[ ] s3","[ ] s4","[ ] s5","[ ] s6","[ ] s7","[ ] s8","[ ] s9"]}' | bash "$MERGE" --project-md "$P3" --knowledge-dir "$WIKI" >/dev/null 2>&1
n=$(awk '/^## Plan$/{f=1;next} /^## /{f=0} f && /^- / && !/\[pinned\]/{c++} END{print c+0}' "$P3")
[ "$n" -le 7 ] || fail "non-pinned plan exceeds cap 7 (got $n)"
grep -q '\[pinned\]' "$P3" || fail "pinned line lost under cap"
pass "non-pinned plan capped at 7, pinned preserved"

# 6. [pinned] decision survives the Recent-decisions cap-5 drop (M7 across sections)
P4="$TMP/p4.md"
cat > "$P4" <<'EOF'
# PROJECT: t

## Plan

## Recent decisions
- [pinned] keep me forever
- [2026-05-01] d1
- [2026-05-02] d2
- [2026-05-03] d3
- [2026-05-04] d4

## Open blockers

## Cross-references

<!-- last_updated: 2026-05-01T00:00:00Z -->
EOF
printf '%s' '{"recent_decisions":["brand new decision"]}' | bash "$MERGE" --project-md "$P4" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -q '\[pinned\] keep me forever' "$P4" || fail "pinned decision dropped at cap (M7 not protecting non-Plan sections)"
grep -q 'brand new decision' "$P4" || fail "new decision not added"
pass "[pinned] decision survives the cap-5 drop"

# 7. M3 scope banner: session-load confirms WHICH project loaded (visible scope) + kill switch
grep -q 'SB_SCOPE_BANNER' "$ROOT/scripts/session-load.sh" || fail "scope banner missing kill switch SB_SCOPE_BANNER"
grep -q 'project memory loaded' "$ROOT/scripts/session-load.sh" || fail "scope banner line missing"
pass "session-load emits a visible project-scope banner (M3)"

# 8. footer survives when ## Plan is the LAST section (hand-edited layout — no trailing ##)
P5="$TMP/p5.md"
cat > "$P5" <<'EOF'
# PROJECT: t

## Goal
g.

## Cross-references

## Plan

- [ ] old

<!-- last_updated: 2026-05-01T00:00:00Z -->
<!-- last_queried_wiki: -->
EOF
printf '%s' '{"plan":["[ ] newp"]}' | bash "$MERGE" --project-md "$P5" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -q '<!-- last_updated:' "$P5" || fail "footer swallowed when ## Plan is the last section"
grep -q 'newp' "$P5" || fail "plan not updated in last-section layout"
pass "footer preserved when ## Plan is the last section"

# 9. re-emitting an identical plan is a NO-OP (no last_updated churn — module contract)
P6="$TMP/p6.md"
cat > "$P6" <<'EOF'
# PROJECT: t

## Plan

- [pinned] north star
- [ ] step one

## Conventions

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: 2026-05-01T00:00:00Z -->
EOF
before=$(grep '<!-- last_updated:' "$P6")
printf '%s' '{"plan":["[ ] step one"]}' | bash "$MERGE" --project-md "$P6" --knowledge-dir "$WIKI" >/dev/null 2>&1
after=$(grep '<!-- last_updated:' "$P6")
[ "$before" = "$after" ] || fail "identical plan re-emit bumped last_updated ($before -> $after)"
pass "identical plan re-emit is a no-op (no last_updated churn)"

# 10. normalization tolerates non-dash bullets / leading whitespace (no double checkbox)
P7="$TMP/p7.md"; seed "$P7"
printf '%s' '{"plan":["* [ ] star item","  bare task"]}' | bash "$MERGE" --project-md "$P7" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -qE '^- \[ \] star item$' "$P7" || fail "'* [ ]' bullet not normalized"
grep -qE '^- \[ \] bare task$' "$P7" || fail "leading-space bare item not normalized"
grep -q '\[ \] \* ' "$P7" && fail "double-checkbox leaked"
pass "plan normalization tolerates */+ bullets and leading whitespace"

echo; echo "ALL PASS"
