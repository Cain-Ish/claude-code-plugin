#!/usr/bin/env bash
# P4 (deep-review): FORGET derives a page's age from its filesystem mtime
# (wiki-forget-score.sh:38). dream-snapshot.sh snapshotted the wiki with plain
# `cp -r`, which RESETS every staged page's mtime to "now"; dream-accept then
# rsyncs those onto live, re-arming the FORGET age-gate corpus-wide so no page
# can ever accumulate enough age to become a candidate. The FORGET recency fix
# (0.24.47) was silently neutered by this.
#
# ORACLE: the page's REAL mtime (a filesystem fact, not a re-read of the
# implementation's own output). A genuinely-old page must keep its old mtime
# through the snapshot.
set -u
unset CLAUDECODE ANTHROPIC_API_KEY SB_EXTRACTOR_LOCAL_URL 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SNAP="$REPO_ROOT/scripts/dream-snapshot.sh"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
export BRAIN_DIR="$SANDBOX/brain"
export KNOWLEDGE_DIR="$SANDBOX/knowledge"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"   # dream-snapshot reads THIS, not bare KNOWLEDGE_DIR
mkdir -p "$BRAIN_DIR/transcripts" "$KNOWLEDGE_DIR/wiki/entities"

# an OLD page (set mtime to 2025-01-01) + a transcript so the snapshot runs
OLD="$KNOWLEDGE_DIR/wiki/entities/ancient.md"
printf -- '---\ntitle: ancient\ntype: entities\nrelated: []\n---\n\n# ancient\n\nbody\n' > "$OLD"
touch -t 202501010000 "$OLD"
printf 'session transcript content\n' > "$BRAIN_DIR/transcripts/sess_2025-01-01.txt"

ORIG_MTIME=$(stat -c %Y "$OLD" 2>/dev/null || stat -f %m "$OLD")

CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$SNAP" --max-count 5 >/dev/null 2>&1 || true

STAGED=$(find "$BRAIN_DIR/dreams" -path '*/staging/wiki/entities/ancient.md' 2>/dev/null | head -1)
[ -n "$STAGED" ] || fail "snapshot did not produce a staged copy of the page"

STAGED_MTIME=$(stat -c %Y "$STAGED" 2>/dev/null || stat -f %m "$STAGED")
NOW=$(date +%s)

# The staged mtime must equal the ORIGINAL old mtime — NOT be reset to ~now.
if [ "$STAGED_MTIME" = "$ORIG_MTIME" ]; then
  pass "snapshot preserves the old page's mtime ($STAGED_MTIME) — FORGET age survives"
else
  DELTA=$(( NOW - STAGED_MTIME ))
  fail "staged mtime reset (orig=$ORIG_MTIME staged=$STAGED_MTIME, ${DELTA}s ago ≈ now) — FORGET age-gate re-armed"
fi

# Sharper: the staged page must be older than the 30-day FORGET MINAGE floor.
AGE_DAYS=$(( (NOW - STAGED_MTIME) / 86400 ))
[ "$AGE_DAYS" -ge 30 ] && pass "staged page age ${AGE_DAYS}d ≥ 30d MINAGE (a real FORGET candidate)" \
  || fail "staged page age ${AGE_DAYS}d < 30d — would be PROTECT:age'd, never forgettable"

# ---------------------------------------------------------------------------
# D095: transcript selection must be by the DATE embedded in the filename,
# newest first, never by lexical filename sort. `<session-id>_<slug>_<date>.txt`
# and `sub-<hex>_<slug>_<date>.txt` both put the date as a SUFFIX; a plain
# `ls | sort -r` puts every sub-* file first ('s' > any hex digit) regardless
# of date. Fixture: 6 UUID-prefixed main-session transcripts dated NEWER
# (2026-08-01..06) + 6 sub-* transcripts dated OLDER (2026-07-01..06). The 6
# newest (the main-session files) must be staged; the 6 older sub-* must not.
rm -rf "$SANDBOX/home2" "$BRAIN_DIR/dreams"
BRAIN_DIR2="$SANDBOX/brain2"
KNOWLEDGE_DIR2="$SANDBOX/knowledge2"
mkdir -p "$BRAIN_DIR2/transcripts" "$KNOWLEDGE_DIR2/wiki/entities"
printf -- '---\ntitle: p\ntype: entities\nrelated: []\n---\n\n# p\n\nbody\n' > "$KNOWLEDGE_DIR2/wiki/entities/p.md"

for d in 01 02 03 04 05 06; do
  uuid="11111111-1111-1111-1111-11111111${d}${d}"
  printf 'main session transcript %s\n' "$d" > "$BRAIN_DIR2/transcripts/${uuid}_proj_2026-08-${d}.txt"
  printf 'sub-agent transcript %s\n' "$d" > "$BRAIN_DIR2/transcripts/sub-aaaa${d}_proj_2026-07-${d}.txt"
done

CLAUDE_PLUGIN_ROOT="$REPO_ROOT" BRAIN_DIR="$BRAIN_DIR2" \
  CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOWLEDGE_DIR2" KNOWLEDGE_DIR="$KNOWLEDGE_DIR2" \
  bash "$SNAP" --max-count 6 >/dev/null 2>&1 || fail "dream-snapshot exited non-zero on the selection fixture"

STAGED_DIR=$(find "$BRAIN_DIR2/dreams" -maxdepth 2 -type d -name transcripts | head -1)
[ -n "$STAGED_DIR" ] || fail "no staged transcripts dir produced"
STAGED_MAIN=$(find "$STAGED_DIR" -name '1111*' | wc -l | tr -d ' ')
STAGED_SUB=$(find "$STAGED_DIR" -name 'sub-*' | wc -l | tr -d ' ')
if [ "$STAGED_MAIN" = "6" ] && [ "$STAGED_SUB" = "0" ]; then
  pass "D095: the 6 newest main-session transcripts are staged, the 6 older sub-* excluded"
else
  fail "D095: selection is not date-ordered (staged main=$STAGED_MAIN sub=$STAGED_SUB, expected main=6 sub=0)"
fi

# ---------------------------------------------------------------------------
# D091: a `cp -rp` failure (or a silent partial copy) must mark the dream
# failed instead of writing a "pending" status.json and letting a half-copied
# staging tree pass dream-accept's floor.
FAKEBIN="$SANDBOX/fakebin-cp-fail"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/cp" <<'EOF'
#!/bin/bash
exit 7
EOF
chmod +x "$FAKEBIN/cp"

BRAIN_DIR3="$SANDBOX/brain3"
KNOWLEDGE_DIR3="$SANDBOX/knowledge3"
mkdir -p "$BRAIN_DIR3/transcripts" "$KNOWLEDGE_DIR3/wiki/entities"
printf -- '---\ntitle: p\ntype: entities\nrelated: []\n---\n\n# p\n\nbody\n' > "$KNOWLEDGE_DIR3/wiki/entities/p.md"
printf 'tx\n' > "$BRAIN_DIR3/transcripts/sess_2026-01-01.txt"

set +e
PATH="$FAKEBIN:$PATH" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" BRAIN_DIR="$BRAIN_DIR3" \
  CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOWLEDGE_DIR3" KNOWLEDGE_DIR="$KNOWLEDGE_DIR3" \
  bash "$SNAP" --max-count 5 >/dev/null 2>/dev/null
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "D091: dream-snapshot exited 0 despite cp failing"

FAILED_STATUS=$(find "$BRAIN_DIR3/dreams" -name status.json -exec jq -r '.status' {} \; 2>/dev/null | head -1)
FAILED_ERR=$(find "$BRAIN_DIR3/dreams" -name status.json -exec jq -r '.error' {} \; 2>/dev/null | head -1)
if [ "$FAILED_STATUS" = "failed" ]; then
  pass "D091: a cp failure marks the dream failed (error: $FAILED_ERR)"
else
  fail "D091: cp exited 7 but status.json status='$FAILED_STATUS' (expected failed)"
fi

echo "ALL PASS"
