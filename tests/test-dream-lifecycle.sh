#!/bin/bash
# Tests for dream lifecycle: snapshot, diff, accept, and lib.sh helpers.
set -u
REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

setup() {
  local name="$1"
  rm -rf "$TMP/$name"
  mkdir -p "$TMP/$name/.second-brain/"{transcripts,dreams}
  mkdir -p "$TMP/$name/knowledge/wiki/"{entities,concepts,learnings}
  export HOME="$TMP/$name"
  export BRAIN_DIR="$HOME/.second-brain"
  export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$HOME/knowledge"
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  source "$REPO_ROOT/scripts/lib.sh"
}

# Seed a wiki with some test pages
seed_wiki() {
  cat > "$HOME/knowledge/wiki/entities/test-entity.md" <<'EOF'
---
title: "Test Entity"
type: entities
description: "A test entity for dream testing"
tags: [test]
---
# Test Entity
This is a test entity page.
EOF

  cat > "$HOME/knowledge/wiki/learnings/test-learning.md" <<'EOF'
---
title: "Test Learning"
type: learnings
description: "A test learning for dream testing"
tags: [test]
---
# Test Learning
Always test before shipping.
EOF
}

# Seed transcripts
seed_transcripts() {
  for i in 1 2 3; do
    cat > "$BRAIN_DIR/transcripts/sess_00${i}_testproj_2026-05-0${i}.txt" <<EOF
--- session-meta ---
session_id: sess_00${i}
project_slug: testproj
date: 2026-05-0${i}
tool_count: ${i}
line_count: 20
---

USER: test question $i
ASSISTANT:
  test response $i
  [Edit] test.ts
EOF
  done
}

# --- Subtest 1: dream ID generation
setup "id-gen"
DID=$(sb_generate_dream_id)
echo "$DID" | grep -q "^drm_" || fail "dream ID should start with drm_ (got: $DID)"
pass "dream ID generation: correct format"

# --- Subtest 2: dream-snapshot.sh creates proper structure
setup "snapshot"
seed_wiki
seed_transcripts
DID=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)
echo "$DID" | grep -q "^drm_" || fail "dream-snapshot should output dream ID (got: $DID)"
[ -f "$BRAIN_DIR/dreams/$DID/status.json" ] || fail "status.json not created"
[ -d "$BRAIN_DIR/dreams/$DID/staging/wiki" ] || fail "staging/wiki not created"
[ -d "$BRAIN_DIR/dreams/$DID/transcripts" ] || fail "transcripts dir not created"

# Check status.json content
STATUS=$(jq -r '.status' "$BRAIN_DIR/dreams/$DID/status.json")
[ "$STATUS" = "pending" ] || fail "initial status should be pending (got: $STATUS)"
TC=$(jq -r '.inputs.transcript_count' "$BRAIN_DIR/dreams/$DID/status.json")
[ "$TC" -eq 3 ] || fail "should have 3 transcripts (got: $TC)"

# Check staging has wiki pages
[ -f "$BRAIN_DIR/dreams/$DID/staging/wiki/entities/test-entity.md" ] || fail "staging wiki missing entity page"
pass "snapshot: creates proper dream structure"

# --- Subtest 3: only one dream pending/running at a time
setup "guard"
seed_wiki
seed_transcripts
DID1=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)
DID2=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)
echo "$DID2" | grep -q "error:" || fail "second dream should be rejected while first is pending"
pass "concurrency guard: rejects second dream"

# --- Subtest 4: dream-diff.sh generates diff
setup "diff"
seed_wiki
seed_transcripts
DID=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)

# Modify a page in staging
echo "## New section from dream" >> "$BRAIN_DIR/dreams/$DID/staging/wiki/entities/test-entity.md"

# Add a new page
cat > "$BRAIN_DIR/dreams/$DID/staging/wiki/learnings/new-insight.md" <<'EOF'
---
title: "New Insight"
type: learnings
description: "Discovered during dreaming"
tags: [test]
---
# New Insight
This was surfaced by dream mining.
EOF

OUT=$(bash "$REPO_ROOT/scripts/dream-diff.sh" "$DID" 2>&1)
echo "$OUT" | grep -q "+1\|~1" || fail "diff should report changes (got: $OUT)"
[ -f "$BRAIN_DIR/dreams/$DID/diff.md" ] || fail "diff.md not created"
grep -q "New Pages" "$BRAIN_DIR/dreams/$DID/diff.md" || fail "diff.md missing sections"

# Check outputs updated in status.json
ADDED=$(jq -r '.outputs.pages_added' "$BRAIN_DIR/dreams/$DID/status.json")
[ "$ADDED" -ge 1 ] || fail "outputs.pages_added should be >= 1 (got: $ADDED)"
pass "diff: generates diff.md and updates status"

# --- Subtest 5: dream-accept.sh applies changes
setup "accept"
seed_wiki
seed_transcripts
DID=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)

# Modify staging
cat > "$BRAIN_DIR/dreams/$DID/staging/wiki/learnings/dream-learning.md" <<'EOF'
---
title: "Dream Learning"
type: learnings
description: "From a dream"
tags: [dream]
---
# Dream Learning
EOF

# Set status to completed (normally dream-diff.sh + execution does this)
jq '.status = "completed" | .ended_at = "2026-05-11T00:00:00Z"' \
  "$BRAIN_DIR/dreams/$DID/status.json" > /tmp/ds.json && mv /tmp/ds.json "$BRAIN_DIR/dreams/$DID/status.json"
bash "$REPO_ROOT/scripts/dream-diff.sh" "$DID" >/dev/null 2>&1

OUT=$(bash "$REPO_ROOT/scripts/dream-accept.sh" "$DID" 2>&1)
echo "$OUT" | grep -q "accepted" || fail "accept should report success (got: $OUT)"

# Check live wiki has the new page
[ -f "$HOME/knowledge/wiki/learnings/dream-learning.md" ] || fail "dream page not applied to live wiki"

# Check dream is archived
ARCHIVED=$(jq -r '.archived_at' "$BRAIN_DIR/dreams/$DID/status.json")
[ "$ARCHIVED" != "null" ] && [ -n "$ARCHIVED" ] || fail "dream should be archived after accept"

# Check staging cleaned up
[ ! -d "$BRAIN_DIR/dreams/$DID/staging" ] || fail "staging should be cleaned up after accept"
pass "accept: applies changes and archives dream"

# --- Subtest 5b (C hardening): a staged OUT-OF-TREE symlink (the escape vector) is REFUSED
setup "accept-symlink-escape"
seed_wiki; seed_transcripts
DID=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)
SECRET="$HOME/secret-outside-wiki.txt"; echo "TOPSECRET" > "$SECRET"
ln -s "$SECRET" "$BRAIN_DIR/dreams/$DID/staging/wiki/learnings/leak.md"   # symlink → outside the wiki
jq '.status="completed"' "$BRAIN_DIR/dreams/$DID/status.json" > /tmp/ds.json && mv /tmp/ds.json "$BRAIN_DIR/dreams/$DID/status.json"
OUT=$(bash "$REPO_ROOT/scripts/dream-accept.sh" "$DID" 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "accept must REFUSE a staged out-of-tree symlink (escape)"
echo "$OUT" | grep -qi 'outside the wiki\|escape' || fail "accept should explain the symlink refusal (got: $OUT)"
[ ! -e "$HOME/knowledge/wiki/learnings/leak.md" ] || fail "the escape symlink reached the LIVE wiki!"
pass "accept refuses an out-of-tree staged symlink (escape blocked)"

# --- Subtest 5c (C hardening): an IN-TREE relative alias symlink is ALLOWED (legit, e.g. latest.md)
setup "accept-symlink-intree"
seed_wiki; seed_transcripts
DID=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)
ln -s "test-entity.md" "$BRAIN_DIR/dreams/$DID/staging/wiki/entities/alias.md"   # relative, in-tree
jq '.status="completed"' "$BRAIN_DIR/dreams/$DID/status.json" > /tmp/ds.json && mv /tmp/ds.json "$BRAIN_DIR/dreams/$DID/status.json"
OUT=$(bash "$REPO_ROOT/scripts/dream-accept.sh" "$DID" 2>&1); RC=$?
[ "$RC" -eq 0 ] || fail "accept must ALLOW an in-tree relative alias (got rc=$RC: $OUT)"
pass "accept allows an in-tree relative alias symlink (legit preserved)"

# --- Subtest 5d (C hardening regression): a SYMLINKED staging ancestor must NOT false-reject a
# legit in-tree alias — the guard must canonicalize the base too (resolve-before-validate). Without
# the fix this breaks every accept on macOS (/private/tmp) / symlinked-home setups.
setup "accept-symlinked-base"
seed_wiki; seed_transcripts
REAL_SB="$HOME/.second-brain-real"; mv "$BRAIN_DIR" "$REAL_SB"; ln -s "$REAL_SB" "$BRAIN_DIR"   # BRAIN_DIR now a symlink
DID=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)
ln -s "test-entity.md" "$BRAIN_DIR/dreams/$DID/staging/wiki/entities/alias.md"   # in-tree alias, via symlinked staging
jq '.status="completed"' "$BRAIN_DIR/dreams/$DID/status.json" > /tmp/ds.json && mv /tmp/ds.json "$BRAIN_DIR/dreams/$DID/status.json"
OUT=$(bash "$REPO_ROOT/scripts/dream-accept.sh" "$DID" 2>&1); RC=$?
[ "$RC" -eq 0 ] || fail "symlinked staging ancestor false-rejected a legit accept (got rc=$RC: $OUT)"
pass "symlinked staging ancestor: legit in-tree alias still accepted (base canonicalized)"

# Build a fake bin that emulates STOCK macOS/BSD: no `realpath`, no `greadlink`, and a
# `readlink` that does NOT support -f (the GNU-only canonicalize flag). Stock macOS bash 3.2
# hosts look exactly like this. Used by subtests 5e/5f.
make_macos_fakebin() {
  local fb="$1"; mkdir -p "$fb"
  local real_readlink; real_readlink=$(command -v readlink)
  printf '#!/bin/bash\nexit 1\n' > "$fb/realpath"
  printf '#!/bin/bash\nexit 1\n' > "$fb/greadlink"
  # BSD readlink: reject -f, otherwise delegate to the real binary (one-level deref).
  printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = "-f" ] && exit 1; done\nexec %s "$@"\n' "$real_readlink" > "$fb/readlink"
  chmod +x "$fb/realpath" "$fb/greadlink" "$fb/readlink"
}

# --- Subtest 5e (macOS portability): with readlink -f / realpath / greadlink UNAVAILABLE,
# a legit IN-TREE alias must STILL be accepted. On such a host bare `readlink -f` yields empty,
# so the old logic flagged EVERY staged symlink (incl. the legit security/latest.md alias) as an
# escape and refused every accept. The escape scan must use a PORTABLE resolver.
setup "accept-macos-intree"
seed_wiki; seed_transcripts
DID=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)
ln -s "test-entity.md" "$BRAIN_DIR/dreams/$DID/staging/wiki/entities/alias.md"   # legit relative in-tree alias
jq '.status="completed"' "$BRAIN_DIR/dreams/$DID/status.json" > /tmp/ds.json && mv /tmp/ds.json "$BRAIN_DIR/dreams/$DID/status.json"
make_macos_fakebin "$HOME/fakebin"
OUT=$(PATH="$HOME/fakebin:$PATH" bash "$REPO_ROOT/scripts/dream-accept.sh" "$DID" 2>&1); RC=$?
[ "$RC" -eq 0 ] || fail "macOS regime (no readlink -f): legit in-tree alias false-rejected (rc=$RC: $OUT)"
pass "accept allows in-tree alias when readlink -f is unavailable (macOS portability)"

# --- Subtest 5f (macOS portability, security non-regression): an OUT-OF-TREE escape must STILL
# be refused under the same no-readlink-f regime (the portable resolver must not weaken the guard).
setup "accept-macos-escape"
seed_wiki; seed_transcripts
DID=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)
SECRET="$HOME/secret-outside-wiki.txt"; echo "TOPSECRET" > "$SECRET"
ln -s "$SECRET" "$BRAIN_DIR/dreams/$DID/staging/wiki/learnings/leak.md"   # symlink → outside the wiki
jq '.status="completed"' "$BRAIN_DIR/dreams/$DID/status.json" > /tmp/ds.json && mv /tmp/ds.json "$BRAIN_DIR/dreams/$DID/status.json"
make_macos_fakebin "$HOME/fakebin"
OUT=$(PATH="$HOME/fakebin:$PATH" bash "$REPO_ROOT/scripts/dream-accept.sh" "$DID" 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "macOS regime: out-of-tree escape NOT refused (rc=$RC: $OUT)"
echo "$OUT" | grep -qi 'outside the wiki\|escape' || fail "macOS regime: escape refusal not explained (got: $OUT)"
[ ! -e "$HOME/knowledge/wiki/learnings/leak.md" ] || fail "macOS regime: escape symlink reached the LIVE wiki!"
pass "accept refuses out-of-tree escape when readlink -f is unavailable (macOS portability)"

# --- Subtest 5g (macOS portability, fail-closed): a DANGLING RELATIVE `../` escape (target's
# parent does not exist) must be refused, not slipped through. sb_realpath fails closed (empty)
# when the target parent can't be resolved, so the prefix test flags it instead of matching an
# unresolved `…/../..` against the in-tree prefix.
setup "accept-macos-dangling-escape"
seed_wiki; seed_transcripts
DID=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)
ln -s "../../../../../../tmp/sb-nonexistent-escape-$$/secret" \
  "$BRAIN_DIR/dreams/$DID/staging/wiki/learnings/dangle.md"   # relative escape to a non-existent parent
jq '.status="completed"' "$BRAIN_DIR/dreams/$DID/status.json" > /tmp/ds.json && mv /tmp/ds.json "$BRAIN_DIR/dreams/$DID/status.json"
make_macos_fakebin "$HOME/fakebin"
OUT=$(PATH="$HOME/fakebin:$PATH" bash "$REPO_ROOT/scripts/dream-accept.sh" "$DID" 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "macOS regime: dangling relative escape NOT refused (rc=$RC: $OUT)"
pass "accept refuses a dangling relative escape, fail-closed (macOS portability)"

# --- Subtest 5h (macOS portability, security — leaf-`..` escape): a symlink whose target ENDS in
# `..` resolves, parent-only, to `…/wiki/..` which glob-MATCHES the in-tree prefix `…/wiki/*` — it
# must NOT be allowed (it physically points one level ABOVE the wiki). The resolver must
# canonicalize a `..`/directory-trailing target WHOLE, not append a raw `..` leaf. (Found by the
# adversarial re-review of the resolver; the parent IS resolvable so 5g's fail-closed didn't cover it.)
setup "accept-macos-leaf-dotdot"
seed_wiki; seed_transcripts
DID=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)
ln -s "../.." "$BRAIN_DIR/dreams/$DID/staging/wiki/learnings/escape.md"   # ../.. from learnings/ = the staging dir (OUTSIDE wiki)
jq '.status="completed"' "$BRAIN_DIR/dreams/$DID/status.json" > /tmp/ds.json && mv /tmp/ds.json "$BRAIN_DIR/dreams/$DID/status.json"
make_macos_fakebin "$HOME/fakebin"
OUT=$(PATH="$HOME/fakebin:$PATH" bash "$REPO_ROOT/scripts/dream-accept.sh" "$DID" 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "macOS regime: leaf-'..' escape NOT refused — resolved to wiki/.. and matched the in-tree prefix (rc=$RC: $OUT)"
pass "accept refuses a leaf-'..' escape that resolves above the wiki (macOS portability)"

# --- Subtest 5i (refusal-message hygiene): a flagged escape whose staged symlink FILENAME contains
# a space must appear INTACT in the refusal message. The old un-quoted `printf '  %s\n' $OOT_LINKS`
# word-split spaced paths across lines (display-only — the gate above it is quoted — but garbled).
setup "accept-spaced-escape"
seed_wiki; seed_transcripts
DID=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)
SECRET="$HOME/secret-outside-wiki.txt"; echo "TOPSECRET" > "$SECRET"
ln -s "$SECRET" "$BRAIN_DIR/dreams/$DID/staging/wiki/learnings/a b.md"   # out-of-tree escape, spaced filename
jq '.status="completed"' "$BRAIN_DIR/dreams/$DID/status.json" > /tmp/ds.json && mv /tmp/ds.json "$BRAIN_DIR/dreams/$DID/status.json"
OUT=$(bash "$REPO_ROOT/scripts/dream-accept.sh" "$DID" 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "spaced-name escape NOT refused (rc=$RC: $OUT)"
echo "$OUT" | grep -qF 'a b.md' || fail "refusal message split the spaced path (want 'a b.md' intact, got: $OUT)"
pass "refusal message shows a spaced escape path intact (read line-by-line, not word-split)"

# --- Subtest 6: dream_set_status helper
setup "set-status"
seed_wiki
seed_transcripts
DID=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)
sb_dream_set_status "$DID" "status" "running"
NEW_STATUS=$(jq -r '.status' "$BRAIN_DIR/dreams/$DID/status.json")
[ "$NEW_STATUS" = "running" ] || fail "set_status should update status (got: $NEW_STATUS)"
pass "set_status helper: updates status.json"

# --- Subtest 7: prune keeps max 5 dreams
setup "prune-dreams"
seed_wiki
for i in $(seq 1 6); do
  DID="drm_2026050${i}T000000Z"
  mkdir -p "$BRAIN_DIR/dreams/$DID"
  jq -nc --arg id "$DID" '{id:$id, status:"completed", archived_at:"2026-05-01"}' > "$BRAIN_DIR/dreams/$DID/status.json"
done
seed_transcripts
NEW_DID=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)
DREAM_COUNT=$(find "$BRAIN_DIR/dreams" -maxdepth 1 -type d -name 'drm_*' | wc -l | tr -d ' ')
[ "$DREAM_COUNT" -le 5 ] || fail "should prune to max 5 dreams (got: $DREAM_COUNT)"
pass "dream pruning: keeps max 5"

# --- Subtest 7b (R4, SCRIPTS-04): a FAILED dream past keep-count loses its
# staging/transcripts (the ~1MB payload) but KEEPS status.json (forensics);
# pending stays untouched entirely.
setup "prune-failed"
seed_wiki
for i in $(seq 1 5); do
  DID="drm_2026050${i}T000000Z"
  mkdir -p "$BRAIN_DIR/dreams/$DID"
  jq -nc --arg id "$DID" '{id:$id, status:"completed", archived_at:"2026-05-01"}' > "$BRAIN_DIR/dreams/$DID/status.json"
done
FID="drm_20260401T000000Z"   # sorts oldest
mkdir -p "$BRAIN_DIR/dreams/$FID/staging/wiki" "$BRAIN_DIR/dreams/$FID/transcripts"
echo x > "$BRAIN_DIR/dreams/$FID/staging/wiki/p.md"
jq -nc --arg id "$FID" '{id:$id, status:"failed", archived_at:null, error:"boom"}' > "$BRAIN_DIR/dreams/$FID/status.json"
# (no pending fixture here: a pending dream trips the one-at-a-time guard and
# dream-snapshot exits BEFORE the prune — that path is subtest 8's coverage;
# the prune's pending-safety is structural: only archived/failed/canceled match.)
seed_transcripts
bash "$REPO_ROOT/scripts/dream-snapshot.sh" >/dev/null 2>&1 || true
[ -f "$BRAIN_DIR/dreams/$FID/status.json" ] || fail "failed dream's status.json must be kept (forensics)"
[ ! -d "$BRAIN_DIR/dreams/$FID/staging" ] || fail "failed dream's staging should be pruned past keep-count"
pass "failed dream pruned to status.json-only (R4)"

# --- Subtest 8 (SP-C): a FRESH pending/running dream blocks a new one (no concurrent runs)
setup "running-block"
seed_wiki; seed_transcripts
RID="drm_20260101T000000Z"; mkdir -p "$BRAIN_DIR/dreams/$RID"
jq -nc --arg id "$RID" '{id:$id, status:"running", archived_at:null}' > "$BRAIN_DIR/dreams/$RID/status.json"
OUT=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "a fresh running dream must block a new one (got rc=$RC)"
echo "$OUT" | grep -qi 'already running' || fail "expected 'already running' (got: $OUT)"
[ "$(jq -r '.status' "$BRAIN_DIR/dreams/$RID/status.json")" = "running" ] || fail "fresh running must stay running"
pass "fresh running dream blocks a new dream (no concurrent runs)"

# --- Subtest 8b (SP-C): a long-but-HEALTHY run (mtime within the timeout) must NOT be reclaimed
# (the deep-review false-positive: mtime is frozen during a run, so the margin must be generous).
setup "running-healthy"
seed_wiki; seed_transcripts
HID="drm_20260101T000000Z"; mkdir -p "$BRAIN_DIR/dreams/$HID"
jq -nc --arg id "$HID" '{id:$id, status:"running", archived_at:null}' > "$BRAIN_DIR/dreams/$HID/status.json"
touch -t "$(date -d '2 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-2H +%Y%m%d%H%M)" "$BRAIN_DIR/dreams/$HID/status.json"
OUT=$(bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1); RC=$?   # default 6h timeout, dream is 2h old
[ "$RC" -ne 0 ] || fail "a 2h-old running dream (under the 6h default) must still block, not reclaim"
[ "$(jq -r '.status' "$BRAIN_DIR/dreams/$HID/status.json")" = "running" ] || fail "2h-old running dream was wrongly reclaimed"
pass "long-but-healthy running dream (under timeout) is NOT reclaimed"

# --- Subtest 9 (SP-C): a STALE running dream (no progress > timeout) is reclaimed → unblocks
setup "running-reclaim"
seed_wiki; seed_transcripts
SID="drm_20260101T000000Z"; mkdir -p "$BRAIN_DIR/dreams/$SID"
jq -nc --arg id "$SID" '{id:$id, status:"running", archived_at:null}' > "$BRAIN_DIR/dreams/$SID/status.json"
touch -t "$(date -d '5 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-5H +%Y%m%d%H%M)" "$BRAIN_DIR/dreams/$SID/status.json"
NEW=$(SB_DREAM_RUN_TIMEOUT=10800 bash "$REPO_ROOT/scripts/dream-snapshot.sh" 2>&1)
[ "$(jq -r '.status' "$BRAIN_DIR/dreams/$SID/status.json")" = "failed" ] || fail "a stale running dream must be reclaimed → failed (deadlock broken)"
echo "$NEW" | grep -q '^drm_' || fail "a new dream should proceed after reclaim (got: $NEW)"
pass "stale running dream reclaimed → failed, new dream proceeds"

echo "ALL PASS"
