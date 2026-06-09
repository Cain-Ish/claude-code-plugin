#!/bin/bash
# Tests for scripts/cost-router-capture.sh (Task 10 — Contract B consumer)
#
# Given a synthetic cost-router-events.jsonl in an isolated dir, the script
# produces cost-routing-patterns.md under the knowledge dir wiki.
# Absent events file → no file created, exit 0.
#
# Isolation: BRAIN_DIR, HOME, and knowledge dir are all rooted under $TMP.
# The real ~/.second-brain and ~/knowledge are never touched.
#
# Usage: bash tests/test-cost-router-capture.sh

set -u

for cmd in jq mktemp bash awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "prerequisite missing: $cmd"; exit 2; }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cost-router-capture.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: script not found: $SCRIPT"
  exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-cost-router-capture.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

echo "test-cost-router-capture.sh"
echo "---------------------------"

# Isolated dirs
BRAIN_DIR="$TMP/brain"
KNOWLEDGE_DIR="$TMP/knowledge"
EVENTS="$TMP/brain/cost-router-events.jsonl"
PATTERNS_PAGE="$KNOWLEDGE_DIR/wiki/cost-routing-patterns.md"

mkdir -p "$BRAIN_DIR" "$KNOWLEDGE_DIR/wiki"

# ── (a) absent events file → exit 0, no output file created ──────────────────
rm -f "$EVENTS" "$PATTERNS_PAGE"
COST_ROUTER_EVENTS="$EVENTS" \
  BRAIN_DIR="$BRAIN_DIR" \
  SB_KNOWLEDGE_DIR="$KNOWLEDGE_DIR" \
  bash "$SCRIPT"
EXIT=$?
if [ "$EXIT" -eq 0 ]; then
  pass "(a) absent events file: exits 0"
else
  fail "(a) absent events file: expected exit 0, got $EXIT"
fi
if [ ! -f "$PATTERNS_PAGE" ]; then
  pass "(a) absent events file: no cost-routing-patterns.md created"
else
  fail "(a) absent events file: cost-routing-patterns.md should NOT be created"
fi

# ── (b) synthetic events → cost-routing-patterns.md created with summary ─────
cat > "$EVENTS" <<'EOF'
{"ts":"2026-06-09T10:00:00Z","task":"add retry","tier":"DO","models":["sonnet"],"units":3,"escalated":false,"outcome":"ok","committed":true}
{"ts":"2026-06-09T10:05:00Z","task":"design api","tier":"THINK","models":["opus"],"units":1,"escalated":true,"outcome":"ok","committed":true}
{"ts":"2026-06-09T10:10:00Z","task":"search code","tier":"SCOUT","models":["haiku"],"units":2,"escalated":false,"outcome":"ok","committed":false}
{"ts":"2026-06-09T10:15:00Z","task":"fix bug","tier":"DO","models":["sonnet"],"units":1,"escalated":false,"outcome":"ok","committed":true}
{"ts":"2026-06-09T10:20:00Z","task":"review pr","tier":"DO","models":["sonnet","opus"],"units":2,"escalated":true,"outcome":"ok","committed":true}
EOF

COST_ROUTER_EVENTS="$EVENTS" \
  BRAIN_DIR="$BRAIN_DIR" \
  SB_KNOWLEDGE_DIR="$KNOWLEDGE_DIR" \
  bash "$SCRIPT"
EXIT=$?
if [ "$EXIT" -eq 0 ]; then
  pass "(b) synthetic events: exits 0"
else
  fail "(b) synthetic events: expected exit 0, got $EXIT"
fi

if [ -f "$PATTERNS_PAGE" ]; then
  pass "(b) synthetic events: cost-routing-patterns.md created"
else
  fail "(b) synthetic events: cost-routing-patterns.md should be created"
fi

# Check the file has meaningful content (at least a markdown header)
if [ -f "$PATTERNS_PAGE" ]; then
  if grep -q '#' "$PATTERNS_PAGE"; then
    pass "(b) cost-routing-patterns.md has markdown header"
  else
    fail "(b) cost-routing-patterns.md has no markdown header"
  fi

  # Check that tier counts appear (DO appeared 3 times, THINK once, SCOUT once)
  if grep -qE 'DO|THINK|SCOUT' "$PATTERNS_PAGE"; then
    pass "(b) tier names appear in summary"
  else
    fail "(b) tier names should appear in summary"
  fi

  # Check escalation mention (2 out of 5 events were escalated)
  if grep -qiE 'escalat' "$PATTERNS_PAGE"; then
    pass "(b) escalation info present in summary"
  else
    fail "(b) escalation info should appear in summary"
  fi

  # Check size is bounded (less than 10000 bytes to keep it small)
  SIZE=$(wc -c < "$PATTERNS_PAGE" | tr -d ' ')
  if [ "$SIZE" -lt 10000 ]; then
    pass "(b) cost-routing-patterns.md is bounded in size ($SIZE bytes)"
  else
    fail "(b) cost-routing-patterns.md too large: $SIZE bytes (cap 10000)"
  fi
fi

# ── (c) re-running updates the file (idempotent) ─────────────────────────────
# Add one more event and run again
echo '{"ts":"2026-06-09T11:00:00Z","task":"new task","tier":"DO","models":["sonnet"],"units":1,"escalated":false,"outcome":"ok","committed":true}' >> "$EVENTS"
COST_ROUTER_EVENTS="$EVENTS" \
  BRAIN_DIR="$BRAIN_DIR" \
  SB_KNOWLEDGE_DIR="$KNOWLEDGE_DIR" \
  bash "$SCRIPT"
EXIT=$?
if [ "$EXIT" -eq 0 ]; then
  pass "(c) second run exits 0"
else
  fail "(c) second run expected exit 0, got $EXIT"
fi
if [ -f "$PATTERNS_PAGE" ]; then
  pass "(c) cost-routing-patterns.md still exists after second run"
else
  fail "(c) cost-routing-patterns.md should still exist after second run"
fi

# ── (d) KNOWLEDGE_DIR fallback from BRAIN_DIR ────────────────────────────────
# Unset SB_KNOWLEDGE_DIR — script should derive knowledge dir from BRAIN_DIR
BRAIN_DIR2="$TMP/brain2"
mkdir -p "$BRAIN_DIR2"
EVENTS2="$BRAIN_DIR2/cost-router-events.jsonl"
cat > "$EVENTS2" <<'EOF'
{"ts":"2026-06-09T12:00:00Z","task":"test fallback","tier":"DO","models":["sonnet"],"units":1,"escalated":false,"outcome":"ok","committed":true}
EOF

COST_ROUTER_EVENTS="$EVENTS2" \
  BRAIN_DIR="$BRAIN_DIR2" \
  HOME="$TMP/fakehome" \
  bash "$SCRIPT"
EXIT=$?
if [ "$EXIT" -eq 0 ]; then
  pass "(d) fallback knowledge dir: exits 0"
else
  fail "(d) fallback knowledge dir: expected exit 0, got $EXIT"
fi

echo "---------------------------"
echo "PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
