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

# 2. replace-reconcile: emitted items land, [pinned] preserved, an omitted unfinished item
# is CARRIED (not dropped) -- merge_plan's carry guard (Slice 1 D3/F5). "old done" ([x], not
# re-emitted) IS retired: [x] lines are never carried, only [ ] lines are.
P="$TMP/p1.md"; seed "$P"
printf '%s' '{"plan":["[ ] new step A","[x] shipped B"]}' | bash "$MERGE" --project-md "$P" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -q '^- \[pinned\] human-authored north star$' "$P" || fail "pinned plan line not preserved"
grep -q 'new step A' "$P" || fail "new plan item not written"
grep -qE '^- \[ \] \[carried [0-9]{4}-[0-9]{2}-[0-9]{2}\] old step one$' "$P" || fail "old non-pinned unfinished plan item was not carried (got: $(awk '/^## Plan$/{f=1;next} /^## /{f=0} f' "$P"))"
grep -q 'old done' "$P" && fail "old done ([x], omitted) should be retired, not carried"
pass "plan replace-reconcile preserves [pinned]; an omitted unfinished item is carried, a done item is retired"

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

# 5. EMITTED lines are capped at 7 (the extractor's own list, before carry); "old step one" is
# additionally carried on top (F5 rescope: the carry guard takes non-pinned unfinished to 8),
# and the pinned line survives untouched.
P3="$TMP/p3.md"; seed "$P3"
printf '%s' '{"plan":["[ ] s1","[ ] s2","[ ] s3","[ ] s4","[ ] s5","[ ] s6","[ ] s7","[ ] s8","[ ] s9"]}' | bash "$MERGE" --project-md "$P3" --knowledge-dir "$WIKI" >/dev/null 2>&1
n=$(awk '/^## Plan$/{f=1;next} /^## /{f=0} f && /^- / && !/\[pinned\]/ && !/\[carried/{c++} END{print c+0}' "$P3")
[ "$n" -le 7 ] || fail "emitted plan lines exceed cap 7 (got $n)"
grep -qE '^- \[ \] \[carried [0-9]{4}-[0-9]{2}-[0-9]{2}\] old step one$' "$P3" || fail "old step one not carried under the cap-7 emission"
grep -q '\[pinned\]' "$P3" || fail "pinned line lost under cap"
pass "emitted plan capped at 7 (excl. carried); old step one carried; pinned preserved"

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

# === Slice 1 §4.2/§4.5 Plan grammar tests (P1-P11) ==========================

# P1: a carried date is sticky; a re-affirmed unrelated line and the whole file stay
# byte-identical (no last_updated churn) when nothing actually changed.
P_P1="$TMP/p_p1.md"
cat > "$P_P1" <<'EOF'
# PROJECT: t

## Plan

- [ ] alpha
- [ ] [carried 2026-09-01] beta

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: 2026-05-01T00:00:00Z -->
EOF
HASH_BEFORE=$(sha256sum "$P_P1" | awk '{print $1}')
printf '%s' '{"plan":["[ ] alpha"]}' | bash "$MERGE" --project-md "$P_P1" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -qE '^- \[ \] \[carried 2026-09-01\] beta$' "$P_P1" || fail "P1: carried date not sticky (beta line changed)"
HASH_AFTER=$(sha256sum "$P_P1" | awk '{print $1}')
[ "$HASH_BEFORE" = "$HASH_AFTER" ] || fail "P1: PROJECT.md sha changed on a re-affirming emission"
pass "P1: a carried date is sticky; an unaffected re-affirmed line leaves the file byte-identical"

# P3: retire with a reason renders exactly; omitted next time it is removed entirely.
P_P3="$TMP/p_p3.md"; seed "$P_P3"
printf '%s' '{"plan":["[x] beta (dropped: obsolete)"]}' | bash "$MERGE" --project-md "$P_P3" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -qE '^- \[x\] beta \(dropped: obsolete\)$' "$P_P3" || fail "P3: retire-with-reason line not rendered exactly"
printf '%s' '{"plan":["[ ] something else"]}' | bash "$MERGE" --project-md "$P_P3" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -q 'beta' "$P_P3" && fail "P3: retired [x] item survived a later omitting emission"
pass "P3: [x] (dropped: why) renders exactly; a later omission removes it entirely"

# P4: revive -- emitting a stale item's text drops the stale wrapper, leaving one open line.
P_P4="$TMP/p_p4.md"
cat > "$P_P4" <<'EOF'
# PROJECT: t

## Plan

- [stale] [ ] [carried 2020-01-01] ancient

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: 2026-05-01T00:00:00Z -->
EOF
printf '%s' '{"plan":["[ ] ancient"]}' | bash "$MERGE" --project-md "$P_P4" --knowledge-dir "$WIKI" >/dev/null 2>&1
N=$(grep -c '^- \[ \] ancient$' "$P_P4")
[ "$N" -eq 1 ] || fail "P4: revive did not leave exactly one - [ ] ancient line (got $N)"
grep -q '\[stale\]' "$P_P4" && fail "P4: stale marker survived a revival"
pass "P4: emitting a stale item's text revives it, dropping the stale wrapper"

# P5: sticky source mark -- reapplied on match; source-first ordering when later carried.
P_P5="$TMP/p_p5.md"
cat > "$P_P5" <<'EOF'
# PROJECT: t

## Plan

- [ ] [untrusted:compact 2026-09-20] fix crlf

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: 2026-05-01T00:00:00Z -->
EOF
printf '%s' '{"plan":["[ ] Fix CRLF"]}' | bash "$MERGE" --project-md "$P_P5" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -qF -- '- [ ] [untrusted:compact 2026-09-20] Fix CRLF' "$P_P5" || fail "P5: sticky source mark not reapplied on a matching emission"
printf '%s' '{"plan":["[ ] something unrelated"]}' | bash "$MERGE" --project-md "$P_P5" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -qE '^- \[ \] \[untrusted:compact 2026-09-20\] \[carried [0-9]{4}-[0-9]{2}-[0-9]{2}\] Fix CRLF$' "$P_P5" \
  || fail "P5: omitting a sticky-marked item did not carry it with both markers (source first)"
pass "P5: sticky source mark reapplied on match; carried keeps source-first ordering when later omitted"

# P7 (D7): forging defence for merge_plan -- neutralize a literal [pinned] token in an emitted
# item; it must stay subject to normal carry/aging, never become an immortal pinned line.
P_P7="$TMP/p_p7.md"; seed "$P_P7"
printf '%s' '{"plan":["[ ] do X [pinned]"]}' | bash "$MERGE" --project-md "$P_P7" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -qF -- '- [ ] do X (pinned)' "$P_P7" || fail "P7: forged [pinned] token not neutralized to (pinned)"
grep -q '\[pinned\] do X' "$P_P7" && fail "P7: forged item still carries a literal [pinned] bracket token"
printf '%s' '{"plan":["[ ] unrelated next step"]}' | bash "$MERGE" --project-md "$P_P7" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -qE '^- \[ \] \[carried [0-9]{4}-[0-9]{2}-[0-9]{2}\] do X \(pinned\)$' "$P_P7" \
  || fail "P7: forged (pinned) item was treated as immortal instead of carried"
pass "P7: D7 -- a forged [pinned] token is neutralized and stays subject to carry/aging"

# P6a: bounds -- overflow beyond the 15-unfinished cap is aged to [stale], never dropped.
P_P6A="$TMP/p_p6a.md"
{
  echo "# PROJECT: t"; echo; echo "## Plan"; echo
  for i in $(seq 1 12); do echo "- [ ] c$i"; done
  echo; echo "## Recent decisions"; echo; echo "## Open blockers"; echo; echo "## Cross-references"; echo
  echo "<!-- last_updated: 2026-05-01T00:00:00Z -->"
} > "$P_P6A"
EMIT_JSON=$(jq -nc '[range(1;8) | "[ ] n\(.)"]')
jq -nc --argjson e "$EMIT_JSON" '{plan: $e}' | bash "$MERGE" --project-md "$P_P6A" --knowledge-dir "$WIKI" >/dev/null 2>&1
OPEN_N=$(awk '/^## Plan$/{f=1;next} /^## /{f=0} f && /^- \[ \]/{c++} END{print c+0}' "$P_P6A")
[ "$OPEN_N" -le 15 ] || fail "P6a: non-pinned unfinished exceeds 15 (got $OPEN_N)"
STALE_N=$(awk '/^## Plan$/{f=1;next} /^## /{f=0} f && /^- \[stale\]/{c++} END{print c+0}' "$P_P6A")
[ "$STALE_N" -eq 4 ] || fail "P6a: expected 4 overflowed-to-stale lines, got $STALE_N"
pass "P6a: bounds overflow ages excess carried items to [stale] instead of dropping them"

# P6b: stale cap 5 -- drop oldest-first, logging each dropped item's text.
P_P6B="$TMP/p_p6b.md"
{
  echo "# PROJECT: t"; echo; echo "## Plan"; echo
  for i in $(seq 1 7); do printf -- '- [stale] [ ] [carried 2020-01-0%d] s%d\n' "$i" "$i"; done
  echo; echo "## Recent decisions"; echo; echo "## Open blockers"; echo; echo "## Cross-references"; echo
  echo "<!-- last_updated: 2026-05-01T00:00:00Z -->"
} > "$P_P6B"
printf '%s' '{"plan":["[ ] fresh item"]}' | bash "$MERGE" --project-md "$P_P6B" --knowledge-dir "$WIKI" >/dev/null 2>&1
STALE_N2=$(awk '/^## Plan$/{f=1;next} /^## /{f=0} f && /^- \[stale\]/{c++} END{print c+0}' "$P_P6B")
[ "$STALE_N2" -eq 5 ] || fail "P6b: expected stale cap 5 after dropping oldest, got $STALE_N2"
DROP_ROWS=$(grep -c 'gate=plan-dropped stale' "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null || echo 0)
[ "$DROP_ROWS" -ge 2 ] || fail "P6b: expected >=2 gate=plan-dropped audit rows, got $DROP_ROWS"
grep -q 'gate=plan-dropped stale text=s1' "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null || fail "P6b: dropped row does not carry the item's text"
pass "P6b: stale cap 5 drops oldest-first, logging each dropped item's text"

# P2: mark_stale ages a [carried] Plan item on ANY merge (not just plan-touching ones).
P_P2="$TMP/p_p2.md"
cat > "$P_P2" <<'EOF'
# PROJECT: t

## Plan

- [ ] [carried 2020-01-01] ancient

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: 2026-05-01T00:00:00Z -->
EOF
printf '%s' '{"recent_decisions":["totally unrelated decision"]}' | bash "$MERGE" --project-md "$P_P2" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -qE '^- \[stale\] \[ \] \[carried 2020-01-01\] ancient$' "$P_P2" \
  || fail "P2: an old [carried] Plan item was not aged to [stale] by an unrelated merge"
pass "P2: mark_stale ages a [carried] Plan item past SB_PROJECT_STALE_DAYS on any merge"

# P8: compact_pending adds an [untrusted:compact TODAY] item, bumps last_updated, logs added=1.
P_P8="$TMP/p_p8.md"; seed "$P_P8"
BEFORE_TS=$(grep '<!-- last_updated:' "$P_P8")
printf '%s' '{"compact_pending":["Wire the PostCompact hook"]}' | bash "$MERGE" --project-md "$P_P8" --knowledge-dir "$WIKI" >/dev/null 2>&1
TODAY_D=$(date +%Y-%m-%d)
grep -qF -- "- [ ] [untrusted:compact $TODAY_D] Wire the PostCompact hook" "$P_P8" || fail "P8: compact_pending item not added with the untrusted marker"
AFTER_TS=$(grep '<!-- last_updated:' "$P_P8")
[ "$BEFORE_TS" != "$AFTER_TS" ] || fail "P8: last_updated not bumped"
grep -q 'gate=compact-pending added=1' "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null || fail "P8: expected an added=1 gate=compact-pending row"
pass "P8: compact_pending adds an [untrusted:compact TODAY] Plan item, bumps last_updated, logs added=1"

# P9: dedup round trip -- exact text, the card's parenthesized form, and punctuation/age noise
# all normalize to the same key as the P8 item; dedup also fires against [x]/pinned/stale lines.
HASH1=$(sha256sum "$P_P8" | awk '{print $1}')
for variant in "Wire the PostCompact hook" \
               "- (untrusted:compact 2026-09-26) Wire the PostCompact hook" \
               "wire  the postcompact HOOK. (3d)" \
               "old done" \
               "human-authored north star"; do
  jq -nc --arg t "$variant" '{compact_pending: [$t]}' | bash "$MERGE" --project-md "$P_P8" --knowledge-dir "$WIKI" >/dev/null 2>&1
  HASH2=$(sha256sum "$P_P8" | awk '{print $1}')
  [ "$HASH1" = "$HASH2" ] || fail "P9: dedup variant '$variant' changed PROJECT.md sha"
  grep -q 'gate=compact-pending added=0 dedup=1' "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null \
    || fail "P9: dedup variant '$variant' did not log added=0 dedup=1"
done
P_P9S="$TMP/p_p9_stale.md"
cat > "$P_P9S" <<'EOF'
# PROJECT: t

## Plan

- [stale] [ ] [carried 2020-01-01] cold item

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: 2026-05-01T00:00:00Z -->
EOF
printf '%s' '{"compact_pending":["cold item"]}' | bash "$MERGE" --project-md "$P_P9S" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -q 'gate=compact-pending added=0 dedup=1' "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null || fail "P9: dedup against an existing [stale] line did not log added=0 dedup=1"
N=$(grep -c 'cold item' "$P_P9S")
[ "$N" -eq 1 ] || fail "P9: compact_pending duplicated a stale line instead of deduping (count=$N)"
pass "P9: compact_pending dedups against its own rendered/normalized forms and [x]/pinned/stale lines"

# P10: compact_pending forging defence -- EVERY [ / ] neutralized to ( / ), not just [pinned].
P_P10="$TMP/p_p10.md"; seed "$P_P10"
printf '%s' '{"compact_pending":["[pinned] x]"]}' | bash "$MERGE" --project-md "$P_P10" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -qF -- '(pinned) x)' "$P_P10" || fail "P10: compact_pending forging defence did not neutralize [ / ] to ( / )"
grep -q '\[pinned\] x\]' "$P_P10" && fail "P10: a literal bracket token leaked through from compact_pending"
pass "P10: compact_pending forging defence replaces every [ with ( and ] with )"

# P11: the 15-unfinished cap refuses new compact adds; a Plan-less PROJECT.md is a no-op.
P_P11="$TMP/p_p11.md"
{
  echo "# PROJECT: t"; echo; echo "## Plan"; echo
  for i in $(seq 1 15); do echo "- [ ] u$i"; done
  echo; echo "## Recent decisions"; echo; echo "## Open blockers"; echo; echo "## Cross-references"; echo
  echo "<!-- last_updated: 2026-05-01T00:00:00Z -->"
} > "$P_P11"
printf '%s' '{"compact_pending":["brand new compact item"]}' | bash "$MERGE" --project-md "$P_P11" --knowledge-dir "$WIKI" >/dev/null 2>&1
grep -q 'gate=compact-pending added=0 dedup=0 refused=1' "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null || fail "P11: expected refused=1 at the 15-unfinished cap"
grep -q 'brand new compact item' "$P_P11" && fail "P11: refused item was added anyway"
pass "P11: compact_pending is refused once non-pinned unfinished lines would reach 15"

P_P11B="$TMP/p_p11b.md"
cat > "$P_P11B" <<'EOF'
# PROJECT: t

## Recent decisions

<!-- last_updated: 2026-05-01T00:00:00Z -->
EOF
HASH_NP=$(sha256sum "$P_P11B" | awk '{print $1}')
printf '%s' '{"compact_pending":["should be a no-op"]}' | bash "$MERGE" --project-md "$P_P11B" --knowledge-dir "$WIKI" >/dev/null 2>&1 || fail "P11: merge exited non-zero on a Plan-less PROJECT.md"
HASH_NP2=$(sha256sum "$P_P11B" | awk '{print $1}')
[ "$HASH_NP" = "$HASH_NP2" ] || fail "P11: compact_pending mutated a PROJECT.md with no ## Plan section"
pass "P11: compact_pending is a no-op when there is no ## Plan section"

echo; echo "ALL PASS"
