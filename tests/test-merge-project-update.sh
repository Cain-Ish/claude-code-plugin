#!/bin/bash
# Tests for scripts/merge-project-update.sh.
# run-all-timeout: 360   (33 merger invocations by design; ~5s each on MSYS — spawn-bound lib.sh, see LC-11)
# Contract: reads JSON delta on stdin (or --json-file), idempotently merges
# into the target PROJECT.md sections, scaffolds wiki pages for missing
# [[refs]] in ~/knowledge/wiki/entities/, updates last_updated. Exits 0 on success;
# non-zero on an unparseable PROJECT.md, invalid JSON, or (since 2026-08-23, EC-13) a
# FAILED PROJECT.md write — so the drainer retries instead of marking the transcript done.
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

# --- Test (P0 rec 1): an issues-category wiki_update writes a real wiki page.
# The category whitelist lived ONLY in extract-prompt.txt — this locks the writer
# half: the merge must route category "issues" to wiki/issues/ like any other
# structured category (no writer-side whitelist regression).
PROJ="$TMP/p10i.md"; WIKI10I="$TMP/wiki10i"; mkdir -p "$WIKI10I"
seed_project "$PROJ"
jq -nc '{
  wiki_updates: [{
    category: "issues",
    slug: "jq-crlf-windows-stdout",
    action: "create",
    title: "jq 1.8.1 emits CRLF on Windows stdout",
    description: "symptom/cause/fix",
    content: "ISSUES BODY SENTINEL: symptom, root cause, fix"
  }]
}' | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI10I" >/dev/null 2>&1 || fail "issues-create: script exited non-zero"
IPAGE="$WIKI10I/wiki/issues/jq-crlf-windows-stdout.md"
[ -f "$IPAGE" ] || fail "issues-create: page $IPAGE was not created"
grep -q '^type: issues$' "$IPAGE" || fail "issues-create: page missing 'type: issues' frontmatter"
grep -qF 'ISSUES BODY SENTINEL' "$IPAGE" || fail "issues-create: content body missing"
pass "wiki_updates create routes category issues to wiki/issues/ (error→fix class unlocked)"

# --- Test (project-first): a new wiki page is stamped with the originating project's
# slug as its project: facet (write-time linkage — before this, no writer set the facet
# and every new page was tier-4 "global" to project-scoped search). An explicit
# project:"" in the update marks the page deliberately global (no facet line).
PROJ_DIR12="$TMP/projects/myproj"; mkdir -p "$PROJ_DIR12"
PROJ="$PROJ_DIR12/PROJECT.md"; WIKI12="$TMP/wiki12"; mkdir -p "$WIKI12"
seed_project "$PROJ"
jq -nc '{
  wiki_updates: [
    {category:"learnings", slug:"proj-stamped",   action:"create", title:"P", description:"d", content:"STAMPED BODY SENTINEL"},
    {category:"learnings", slug:"global-learning", action:"create", title:"G", description:"d", content:"GLOBAL BODY SENTINEL", project:""}
  ]
}' | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI12" >/dev/null 2>&1 || fail "proj-stamp: script exited non-zero"
SPAGE="$WIKI12/wiki/learnings/proj-stamped.md"
[ -f "$SPAGE" ] || fail "proj-stamp: page not created"
grep -q '^project: myproj$' "$SPAGE" || fail "proj-stamp: default project: facet missing (got: $(cat "$SPAGE"))"
GPAGE="$WIKI12/wiki/learnings/global-learning.md"
[ -f "$GPAGE" ] || fail "proj-stamp: global page not created"
if grep -q '^project:' "$GPAGE"; then fail "proj-stamp: explicit project:\"\" override must yield NO facet"; fi
pass "wiki_updates create stamps project: from originating slug; \"\" override stays global"

# --- Test (project-first): rotated-out decisions land in a PER-PROJECT decisions log
# carrying the project: facet — not the shared cross-project global file.
PROJ_DIR13="$TMP/projects/myproj2"; mkdir -p "$PROJ_DIR13"
PROJ="$PROJ_DIR13/PROJECT.md"; WIKI13="$TMP/wiki13"; mkdir -p "$WIKI13"
seed_project "$PROJ"
jq -nc '{recent_decisions:["rot d1","rot d2","rot d3","rot d4","rot d5","rot d6"]}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI13" >/dev/null 2>&1 || fail "decisions-log: script exited non-zero"
DLOG="$WIKI13/wiki/decisions/myproj2-decisions-log.md"
[ -f "$DLOG" ] || fail "decisions-log: per-project log $DLOG not created (rotation should overflow the cap)"
grep -q '^project: myproj2$' "$DLOG" || fail "decisions-log: project: facet missing from log frontmatter"
[ -f "$WIKI13/wiki/decisions/project-decisions-log.md" ] && fail "decisions-log: global log must NOT be created when the slug is known"
pass "rotated decisions archive to per-project decisions log with project: facet"

# --- Test (project-first fallback branches): the charset gate's REJECT path and the
# dotted-slug ACCEPT path, plus a non-empty per-update override. Fixtures elsewhere
# are all clean-alnum, so without these the guard branches are dead code to the suite.
# (a) dotted project dir (real class: my.app) keeps facet + wiki-writes counter.
PROJ_DIRD="$TMP/projects/my.app"; mkdir -p "$PROJ_DIRD"
PROJ="$PROJ_DIRD/PROJECT.md"; WIKI14="$TMP/wiki14"; mkdir -p "$WIKI14"
export BRAIN_DIR="$TMP/brain14"; mkdir -p "$BRAIN_DIR"
seed_project "$PROJ"
jq -nc '{wiki_updates:[{category:"learnings", slug:"dotted-page", action:"create", title:"D", description:"d", content:"DOTTED BODY SENTINEL"}]}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI14" >/dev/null 2>&1 || fail "dotted-slug: script exited non-zero"
grep -q '^project: my.app$' "$WIKI14/wiki/learnings/dotted-page.md" || fail "dotted-slug: facet missing for dotted project dir"
[ -f "$BRAIN_DIR/projects/my.app/.wiki-writes" ] || fail "dotted-slug: wiki-writes counter did not fire for dotted slug"
pass "dotted project slug keeps project: facet AND wiki-writes counter"

# (b) charset-unsafe dir name (space) → no facet, no crash, blank slug logged loudly.
PROJ_DIRU="$TMP/projects/bad name"; mkdir -p "$PROJ_DIRU"
PROJ="$PROJ_DIRU/PROJECT.md"; WIKI15="$TMP/wiki15"; mkdir -p "$WIKI15"
export BRAIN_DIR="$TMP/brain15"; mkdir -p "$BRAIN_DIR"
seed_project "$PROJ"
jq -nc '{wiki_updates:[{category:"learnings", slug:"unsafe-origin", action:"create", title:"U", description:"d", content:"UNSAFE ORIGIN BODY"}]}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI15" >/dev/null 2>&1 || fail "unsafe-slug: script exited non-zero"
UPAGE="$WIKI15/wiki/learnings/unsafe-origin.md"
[ -f "$UPAGE" ] || fail "unsafe-slug: page not created"
if grep -q '^project:' "$UPAGE"; then fail "unsafe-slug: charset-rejected dir name must yield NO facet"; fi
grep -q "fails the facet charset" "$BRAIN_DIR/error-log.jsonl" 2>/dev/null \
  || fail "unsafe-slug: blanking was not logged to error-log (silent disable of counters)"
pass "charset-unsafe project dir → no facet, loud error-log entry"

# (c) non-empty per-update override attributes the page to ANOTHER project.
PROJ_DIRO="$TMP/projects/homeproj"; mkdir -p "$PROJ_DIRO"
PROJ="$PROJ_DIRO/PROJECT.md"; WIKI16="$TMP/wiki16"; mkdir -p "$WIKI16"
export BRAIN_DIR="$TMP/brain16"; mkdir -p "$BRAIN_DIR"
seed_project "$PROJ"
jq -nc '{wiki_updates:[{category:"learnings", slug:"other-team-page", action:"create", title:"O", description:"d", content:"OVERRIDE BODY SENTINEL", project:"other-team"}]}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI16" >/dev/null 2>&1 || fail "override: script exited non-zero"
grep -q '^project: other-team$' "$WIKI16/wiki/learnings/other-team-page.md" \
  || fail "override: non-empty project override not honored"
pass "per-update project override attributes page to the named project"

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

# --- Tests (P0 rec 2): procedures[] → ## How-to runbook block -------------------
# Contract: extractor-emitted procedures land as ONE compact line each under
# ## How-to (created before ## Recent decisions when absent — the hot-tier 3000B
# cap truncates the TAIL, so runbooks must not land after the footer); dedup is
# by task_verb case-insensitively (newest wins); section capped at 5 entries;
# empty/absent procedures is a byte-identical no-op.
PROJ="$TMP/p13.md"; WIKI13="$TMP/wiki13"; mkdir -p "$WIKI13"
seed_project "$PROJ"
jq -nc '{
  procedures: [
    {task_verb:"build", exact_commands:"npm ci --prefix mcp && cd mcp && npm run bundle",
     preconditions:"node >=18", gotcha_avoided:"stale dist bundle ships reviewed-source-but-old-code"},
    {task_verb:"test", exact_commands:"bash tests/run-all.sh", preconditions:"", gotcha_avoided:""}
  ]
}' | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI13" >/dev/null 2>&1 || fail "howto: script exited non-zero"
grep -q '^## How-to$' "$PROJ" || fail "howto: ## How-to section not created"
grep -q '^- build: npm ci --prefix mcp' "$PROJ" || fail "howto: build runbook line missing (got: $(awk '/^## How-to$/{f=1;next} /^## /{f=0} f' "$PROJ"))"
grep -q 'needs: node >=18' "$PROJ" || fail "howto: preconditions not rendered"
grep -q 'avoids: stale dist bundle' "$PROJ" || fail "howto: gotcha_avoided not rendered"
grep -q '^- test: bash tests/run-all.sh$' "$PROJ" || fail "howto: bare runbook (no pre/gotcha) renders without suffixes"
# Placement: the section must appear BEFORE ## Recent decisions (head-survivable
# under the 3000B injection truncation).
HOWTO_LN=$(grep -n '^## How-to$' "$PROJ" | cut -d: -f1)
DEC_LN=$(grep -n '^## Recent decisions$' "$PROJ" | cut -d: -f1)
[ "$HOWTO_LN" -lt "$DEC_LN" ] || fail "howto: section landed after ## Recent decisions (tail-truncation casualty)"
pass "procedures: ## How-to created before decisions, one line per runbook"

# Replace-by-verb: a newer build runbook supersedes the old line (no accumulation).
jq -nc '{procedures: [{task_verb:"Build", exact_commands:"make bundle", preconditions:"", gotcha_avoided:""}]}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI13" >/dev/null 2>&1 || fail "howto-replace: script exited non-zero"
N=$(awk '/^## How-to$/{f=1;next} /^## /{f=0} f && /^- /' "$PROJ" | grep -ci '^- build:' || true)
[ "$N" -eq 1 ] || fail "howto-replace: expected exactly 1 build line after same-verb update, got $N"
grep -q '^- Build: make bundle$' "$PROJ" || fail "howto-replace: newest build runbook did not win"
grep -q '^- test: bash tests/run-all.sh$' "$PROJ" || fail "howto-replace: unrelated test runbook was lost"
pass "procedures: same-verb runbook replaced in place (newest wins, case-insensitive)"

# Cap 5: seeding 6 distinct verbs leaves 5, oldest dropped.
for v in v1 v2 v3 v4 v5 v6; do
  jq -nc --arg v "$v" '{procedures:[{task_verb:$v, exact_commands:("cmd-"+$v), preconditions:"", gotcha_avoided:""}]}' \
    | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI13" >/dev/null 2>&1
done
N=$(awk '/^## How-to$/{f=1;next} /^## /{f=0} f && /^- /' "$PROJ" | wc -l | tr -d ' ')
[ "$N" -eq 5 ] || fail "howto-cap: expected 5 entries after overflow, got $N"
grep -q '^- v6: cmd-v6$' "$PROJ" || fail "howto-cap: newest entry v6 missing"
awk '/^## How-to$/{f=1;next} /^## /{f=0} f' "$PROJ" | grep -q '^- Build:' && fail "howto-cap: oldest entries not dropped (Build survived a 6-verb overflow past cap 5)"
pass "procedures: How-to capped at 5, oldest dropped"

# Empty/absent procedures → byte-identical no-op.
ORIG_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
jq -nc '{procedures: []}' | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI13" >/dev/null 2>&1 || fail "howto-empty: script exited non-zero"
NEW_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
[ "$ORIG_HASH" = "$NEW_HASH" ] || fail "howto-empty: empty procedures mutated PROJECT.md"
# Malformed entries (missing verb or commands) are skipped, not rendered.
jq -nc '{procedures: [{task_verb:"", exact_commands:"x"}, {task_verb:"y", exact_commands:""}]}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI13" >/dev/null 2>&1
NEW_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
[ "$ORIG_HASH" = "$NEW_HASH" ] || fail "howto-malformed: entry without verb/commands must be skipped"
pass "procedures: empty + malformed emissions are no-ops"

# --- EC-13 (2026-08-23): a FAILED PROJECT.md write must exit non-zero, never 0. ----------------
# Before: `mv "$TMP_OUT" "$PROJECT_MD"` unchecked + unconditional `exit 0`. The drainer recorded
# outcome:ok, the archive cap evicted the transcript FIRST as "already extracted", the health
# file stayed ok, no log row. Reproduce: make the PROJECT.md path a DIRECTORY so mv cannot
# replace it (portable across MSYS/Linux/macOS; chmod-based read-only is unreliable on Windows).
EC13=$(mktemp -d); mkdir -p "$EC13/projects/p"
printf '# P\n\n## Recent decisions\n' > "$EC13/projects/p/PROJECT.md"   # a REAL file: the -f precondition passes
EC13_KD="$EC13/knowledge"; mkdir -p "$EC13_KD/wiki"
# Fault injection, portable on MSYS/Linux/macOS: a `mv` wrapper on PATH that refuses ONLY the
# final PROJECT.md replacement (every other mv in the script proceeds normally).
EC13_BIN="$EC13/bin"; mkdir -p "$EC13_BIN"
cat > "$EC13_BIN/mv" <<'EOF'
#!/bin/bash
for a in "$@"; do case "$a" in */PROJECT.md) echo "mv: injected write failure: $a" >&2; exit 1 ;; esac; done
exec /usr/bin/mv "$@" 2>/dev/null || exec "$(command -v -p mv)" "$@"
EOF
chmod +x "$EC13_BIN/mv"
EC13_RC=0
printf '{"recent_decisions":["ec13 decision"]}' \
  | PATH="$EC13_BIN:$PATH" BRAIN_DIR="$EC13" bash "$SCRIPT" --project-md "$EC13/projects/p/PROJECT.md" --knowledge-dir "$EC13_KD" >/dev/null 2>&1 || EC13_RC=$?
[ "$EC13_RC" -ne 0 ] || fail "EC-13: PROJECT.md write failed (injected mv failure) but merge exited 0 — the drainer would mark the transcript extracted and evict it"
grep -q 'PROJECT.md write FAILED' "$EC13/error-log.jsonl" 2>/dev/null \
  || fail "EC-13: failed write left no error-log row (got rc=$EC13_RC but silent)"
pass "EC-13: failed PROJECT.md write exits $EC13_RC (non-zero) and logs loudly — drainer will retry, not evict"
rm -rf "$EC13"

# --- Tests (decision-ritual 0.48.0): handoff section --------------------------------
# Contract: .handoff renders as replace-style ## Handoff (in-flight/failed/see lines),
# created BEFORE ## Recent decisions, capped at 600B at line boundaries, replaced by
# the next session's emission, and an empty emission is a byte-identical no-op.
PROJ="$TMP/p20.md"; WIKI20="$TMP/wiki20"; mkdir -p "$WIKI20"
seed_project "$PROJ"
jq -nc '{handoff:{in_flight:"step 3 of decision ritual half-done",
  failed_approaches:["per-turn hook — MSYS spawn tax","skill-only — no machine lock"],
  pointers:["scripts/merge-project-update.sh:426 — decisions loop","mcp/src/tools/pin-to-project.ts:60 — supersedes scan"]}}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI20" >/dev/null 2>&1 || fail "handoff: script exited non-zero"
grep -q '^## Handoff$' "$PROJ" || fail "handoff: section not created"
grep -q '^in-flight: step 3 of decision ritual half-done$' "$PROJ" || fail "handoff: in_flight line missing"
grep -q '^- failed: per-turn hook — MSYS spawn tax$' "$PROJ" || fail "handoff: failed_approaches line missing"
grep -q '^- see: scripts/merge-project-update.sh:426 — decisions loop$' "$PROJ" || fail "handoff: pointer line missing"
HO_LN=$(grep -n '^## Handoff$' "$PROJ" | cut -d: -f1)
DEC_LN=$(grep -n '^## Recent decisions$' "$PROJ" | cut -d: -f1)
[ "$HO_LN" -lt "$DEC_LN" ] || fail "handoff: section landed after ## Recent decisions (tail-truncation casualty)"
pass "handoff: written before decisions with in-flight/failed/see lines"

# Replace, never accumulate: a later session's handoff fully replaces this one.
jq -nc '{handoff:{in_flight:"now on step 5",failed_approaches:[],pointers:[]}}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI20" >/dev/null 2>&1 || fail "handoff-replace: script exited non-zero"
N=$(grep -c '^in-flight: ' "$PROJ" || true)
[ "$N" -eq 1 ] || fail "handoff-replace: expected exactly 1 in-flight line, got $N"
grep -q '^in-flight: now on step 5$' "$PROJ" || fail "handoff-replace: new handoff did not win"
grep -q 'MSYS spawn tax' "$PROJ" && fail "handoff-replace: old failed_approaches survived the replace"
pass "handoff: replace-style — next session's handoff wins, nothing accumulates"

# Empty emission is a byte-identical no-op (a degraded session never wipes the handoff).
ORIG_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
jq -nc '{handoff:{in_flight:"",failed_approaches:[],pointers:[]}}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI20" >/dev/null 2>&1 || fail "handoff-empty: script exited non-zero"
NEW_HASH=$(sha256sum "$PROJ" | awk '{print $1}')
[ "$ORIG_HASH" = "$NEW_HASH" ] || fail "handoff-empty: empty handoff mutated PROJECT.md (wiped a real handoff or churned last_updated)"
pass "handoff: empty emission is a no-op"

# 600B cap, truncated at LINE boundaries (hot-tier byte discipline).
LONG_PTRS=$(jq -nc '[range(5) | "very/long/path/segment/number/\(.)/deep/file.ts:123 — an intentionally verbose pointer description meant to overflow the byte budget"]')
jq -nc --argjson p "$LONG_PTRS" '{handoff:{in_flight:"overflow probe with a deliberately long in-flight line that occupies real bytes",failed_approaches:["approach one that failed for verbose reasons — details details details","approach two that failed for verbose reasons — details details details","approach three that failed for verbose reasons — details details details"],pointers:$p}}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI20" >/dev/null 2>&1 || fail "handoff-cap: script exited non-zero"
HO_BYTES=$(awk '/^## Handoff$/{f=1;next} /^## /{f=0} f' "$PROJ" | wc -c | tr -d ' ')
[ "$HO_BYTES" -le 620 ] || fail "handoff-cap: section body is ${HO_BYTES}B, cap is 600B (+header slack)"
awk '/^## Handoff$/{f=1;next} /^## /{f=0} f && /^- see: /' "$PROJ" | grep -q ' — an int$' && fail "handoff-cap: truncation cut mid-line, not at a line boundary"
pass "handoff: 600B cap enforced at line boundaries"

# --- Test (decision-ritual): reversal-phrased decision marks the old bullet superseded.
# Locks the extract-prompt phrasing contract end-to-end: override language + word overlap
# (detect_supersede) → old bullet gets '- [superseded] ', new bullet lands unsuperseded.
PROJ="$TMP/p21.md"; WIKI21="$TMP/wiki21"; mkdir -p "$WIKI21"
seed_project "$PROJ"
jq -nc '{recent_decisions:["no longer picked X over Y — reversed because W broke"]}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI21" >/dev/null 2>&1 || fail "supersede-phrase: script exited non-zero"
grep -q '^- \[superseded\] \[decision\] picked X over Y$' "$PROJ" \
  || fail "supersede-phrase: old bullet not marked [superseded] (got: $(awk '/^## Recent decisions$/{f=1;next} /^## /{f=0} f' "$PROJ"))"
grep -q 'no longer picked X over Y — reversed because W broke' "$PROJ" || fail "supersede-phrase: new reversal decision missing"
grep -q '^- \[superseded\].*no longer picked' "$PROJ" && fail "supersede-phrase: NEW bullet must not be superseded"
pass "reversal phrasing marks old decision [superseded], never deletes it"

# --- Test (decision-ritual): gate=decision-capture TRACE row in the audit log.
# pinned = dedup-hit (decision already in PROJECT.md when Stop extraction found it),
# stop_only = fresh insert. One row per merge with a non-empty decisions delta.
export BRAIN_DIR="$TMP/brain22"; mkdir -p "$BRAIN_DIR"
PROJ="$TMP/p22.md"; WIKI22="$TMP/wiki22"; mkdir -p "$WIKI22"
seed_project "$PROJ"
jq -nc '{recent_decisions:["picked X over Y","use haiku for extraction because cheap"]}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI22" >/dev/null 2>&1 || fail "capture-metric: script exited non-zero"
grep -q 'gate=decision-capture pinned=1 stop_only=1' "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null \
  || fail "capture-metric: expected 'gate=decision-capture pinned=1 stop_only=1' in audit-log (got: $(cat "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null | tail -3))"
# Metric is TRACE, not error: the row must NOT land in error-log.jsonl.
grep -q 'gate=decision-capture' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null \
  && fail "capture-metric: TRACE row leaked into error-log.jsonl"
pass "gate=decision-capture pinned/stop_only TRACE row lands in audit-log"
# ASYMMETRIC fixture (review finding): 2 dups + 1 fresh — a swapped pinned/stop_only
# conditional would emit pinned=1 stop_only=2 and fail here; the symmetric 1/1 case
# above cannot see the swap.
jq -nc '{recent_decisions:["picked X over Y","use haiku for extraction because cheap","brand new third choice for the asymmetry probe"]}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI22" >/dev/null 2>&1 || fail "capture-metric-asym: script exited non-zero"
grep -q 'gate=decision-capture pinned=2 stop_only=1' "$BRAIN_DIR/audit-log.jsonl" \
  || fail "capture-metric-asym: expected pinned=2 stop_only=1 (swap-sensitive) — got: $(tail -2 "$BRAIN_DIR/audit-log.jsonl")"
pass "gate=decision-capture counters are direction-locked (asymmetric 2-dup/1-fresh fixture)"

# --- Copilot PR-99 finding: [superseded]/[stale] bullets must NOT be dedup targets.
# grep -qF is a substring match, so a superseded line containing the original text
# silently blocked a legitimate flip-flop re-pin AND inflated the pinned counter.
export BRAIN_DIR="$TMP/brain23"; mkdir -p "$BRAIN_DIR"
PROJ="$TMP/p23.md"; WIKI23="$TMP/wiki23"; mkdir -p "$WIKI23"
seed_project "$PROJ"
# Plant a superseded bullet carrying the exact text about to be re-pinned.
awk '{ print } /^## Recent decisions$/ { print "- [superseded] [decision] old cap two hundred" }' "$PROJ" > "$PROJ.t" && mv "$PROJ.t" "$PROJ"
jq -nc '{recent_decisions:["old cap two hundred"]}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI23" >/dev/null 2>&1 || fail "flipflop: script exited non-zero"
N=$(grep -c 'old cap two hundred' "$PROJ" || true)
[ "$N" -eq 2 ] || fail "flipflop: re-pin of a superseded decision must insert fresh (expected 2 occurrences: superseded + new; got $N)"
grep -q 'gate=decision-capture pinned=0 stop_only=1' "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null \
  || fail "flipflop: superseded dedup-hit must not count as pinned (got: $(tail -1 "$BRAIN_DIR/audit-log.jsonl" 2>/dev/null))"
pass "superseded bullet is not a dedup target: flip-flop re-pin inserts fresh, metric counts stop_only"
export BRAIN_DIR="$TMP/brain"

# --- D142: recent_decisions/open_blockers/plan/cross_refs must drop non-string
# elements (logged once) and flatten embedded CR/LF to a space, so ONE malformed
# or multi-line element becomes exactly ONE bullet — never several independently
# dated/capped fragments (object braces, "why": ... keys, injected headings).
export BRAIN_DIR="$TMP/brain24"; mkdir -p "$BRAIN_DIR"
PROJ="$TMP/p24.md"; WIKI24="$TMP/wiki24"; mkdir -p "$WIKI24"
seed_project "$PROJ"
jq -nc '{recent_decisions:[{"text":"obj decision here","why":"because reasons apply"},"line one of it\nline two of it"]}' \
  | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI24" >/dev/null 2>&1 || fail "D142: script exited non-zero"
DEC_SECTION=$(awk '/^## Recent decisions$/{f=1;next} /^## /{f=0} f' "$PROJ")
NEW_BULLETS=$(printf '%s\n' "$DEC_SECTION" | grep -c '^- ')
[ "$NEW_BULLETS" -eq 2 ] \
  || fail "D142: expected exactly 2 decision bullets (1 seeded + 1 new flattened), got $NEW_BULLETS: $DEC_SECTION"
printf '%s\n' "$DEC_SECTION" | grep -qE '^- \[[0-9-]+\] line one of it line two of it$' \
  || fail "D142: multi-line string element must flatten to ONE bullet, embedded newline collapsed to a space (got: $DEC_SECTION)"
printf '%s\n' "$DEC_SECTION" | grep -qE '"why"|^\- \[.*\] \}$' \
  && fail "D142: object element leaked brace/key fragments into PROJECT.md (got: $DEC_SECTION)"
grep -q 'recent_decisions: dropped 1 non-string element' "$BRAIN_DIR/error-log.jsonl" 2>/dev/null \
  || fail "D142: expected one sb_log_error row noting the dropped non-string element"
pass "D142: non-string decision dropped+logged once, multi-line string flattened to one bullet"

# --- D143: wiki_updates content dedup must treat its 60-byte content_check as
# ONE literal pattern, not a newline-delimited LIST of alternate patterns
# (grep -F's documented behavior for a multi-line PATTERN arg). A recurring
# first line ("Symptom: ...") must not, on its own, drop an update whose later
# lines are genuinely new.
export BRAIN_DIR="$TMP/brain25"; mkdir -p "$BRAIN_DIR"
PROJ="$TMP/p25.md"; WIKI25="$TMP/wiki25"; mkdir -p "$WIKI25/wiki/issues"
seed_project "$PROJ"
OLDPAGE="$WIKI25/wiki/issues/old-page.md"
cat > "$OLDPAGE" <<'EOF'
---
title: "old"
type: issues
---

# old

Symptom: something
EOF
UPDATE_JSON='{"wiki_updates":[{"category":"issues","slug":"old-page","action":"update","content":"Symptom: something\nCause: brand new root cause\nFix: apply the new fix"}]}'
printf '%s' "$UPDATE_JSON" | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI25" >/dev/null 2>&1 || fail "D143: script exited non-zero"
grep -q 'brand new root cause' "$OLDPAGE" \
  || fail "D143: update with a recurring first line ('Symptom: something') was wrongly dropped as a duplicate"
pass "D143: recurring first line alone does not drop an update with genuinely new later lines"
# Re-running the SAME update must still be a real no-op (true duplicate, full
# content already present) — the fix must not turn off dedup entirely.
BEFORE_LINES=$(wc -l < "$OLDPAGE")
printf '%s' "$UPDATE_JSON" | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$WIKI25" >/dev/null 2>&1 || fail "D143: re-run exited non-zero"
AFTER_LINES=$(wc -l < "$OLDPAGE")
[ "$BEFORE_LINES" -eq "$AFTER_LINES" ] \
  || fail "D143: re-applying the identical update was not deduped (before=$BEFORE_LINES after=$AFTER_LINES)"
pass "D143: an identical re-applied update is still deduped as a true duplicate"

echo "ALL PASS"
