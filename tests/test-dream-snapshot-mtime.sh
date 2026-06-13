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

echo "ALL PASS"
