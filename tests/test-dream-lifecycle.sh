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
