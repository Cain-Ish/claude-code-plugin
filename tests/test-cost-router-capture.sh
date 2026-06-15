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
PATTERNS_PAGE="$KNOWLEDGE_DIR/wiki/state/cost-routing-patterns.md"

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

  # Check that tier counts are NONZERO (catches the -s/slurp bug where all counts come out 0)
  # DO appeared 3 times in 5 events → the table row should show "3" not "0"
  _DO_ROW=$(grep 'DO (Sonnet' "$PATTERNS_PAGE" 2>/dev/null || true)
  _DO_NUM=$(printf '%s\n' "$_DO_ROW" | grep -oE '\| [0-9]+' | head -1 | tr -d '| ' || echo "0")
  if [ "${_DO_NUM:-0}" -ge 1 ] 2>/dev/null; then
    pass "(b) DO tier count is nonzero in summary (got: $_DO_NUM)"
  else
    fail "(b) DO tier count should be nonzero (got: '$_DO_ROW') — possible jq -s missing bug"
  fi

  # (b) Escalation BULLET must render with its COUNT — not merely the word.
  # Pre-0.29.3 bug: `printf '- ...'` (leading-dash format) was parsed by bash as a
  # printf OPTION ("printf: - : invalid option") → every bullet under ## Escalation
  # AND ## Notes was silently dropped, so the orchestrator (which READS this page to
  # bias tier decisions) got blank escalation data. The old check `grep -qiE 'escalat'`
  # passed anyway because the "## Escalation" HEADING matches the word. Assert the DATA.
  if grep -qE 'Total escalated to Opus:.*[0-9]+ of [0-9]+' "$PATTERNS_PAGE"; then
    pass "(b) escalation BULLET renders with counts (not just the heading word)"
  else
    fail "(b) escalation bullet DROPPED — printf leading-dash option bug; orchestrator reads blank data"
  fi

  # (b) GENERAL structural oracle (independent of HOW the body is built): no '## section'
  # may be empty — a heading followed only by blanks until the next '## ' or EOF means
  # content was silently dropped. Catches ANY future content-drop in the generator.
  _EMPTY_SECTS=$(awk '
    function flush(){ if (cur != "" && !seen) empties = empties " [" cur "]" }
    /^## /    { flush(); sub(/^## /,"",$0); cur=$0; seen=0; next }
    /^# /     { next }
    NF        { if (cur != "") seen=1 }
    END       { flush(); sub(/^ /,"",empties); print empties }
  ' "$PATTERNS_PAGE")
  if [ -z "$_EMPTY_SECTS" ]; then
    pass "(b) every '## section' has body content (no silently-dropped sections)"
  else
    fail "(b) EMPTY section(s) — content silently dropped:$_EMPTY_SECTS"
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

# --- R5.1 (CR-007): the page is born VALID — frontmatter present so
# knowledge_validate never autofixes it and the next capture never strips it
# back (the churn loop), and it lives under wiki/state/ (root is unindexed).
if [ -f "$PATTERNS_PAGE" ]; then
  head -1 "$PATTERNS_PAGE" | grep -qx -- '---' || fail "(e) page lacks frontmatter fence"
  grep -q '^type: state' "$PATTERNS_PAGE" || fail "(e) page lacks type: state"
  grep -q '^generated: true' "$PATTERNS_PAGE" || fail "(e) page lacks generated: true"
  grep -q 'do not hand-edit' "$PATTERNS_PAGE" || fail "(e) page lacks the generated marker"
  # Born-valid = valid by the REAL validator. Assert EVERY required field (incl. tags +
  # related, the pair the helper used to omit → eternal autofix↔regenerate churn). The
  # set is derived from knowledge-validate.ts so it tracks the validator, not a copy.
  _req=$(grep -m1 'REQUIRED_FM_FIELDS *=' "$REPO_ROOT/mcp/src/tools/knowledge-validate.ts" | grep -oE "'[a-z]+'" | tr -d "'")
  _miss=""
  for k in $_req; do grep -qE "^${k}:" "$PATTERNS_PAGE" || _miss="$_miss $k"; done
  [ -z "$_miss" ] && pass "(e) generated page born-valid vs validator REQUIRED_FM_FIELDS (under wiki/state/)" \
                   || fail "(e) generated page incomplete — missing required field(s):$_miss"
else
  fail "(e) patterns page missing for frontmatter checks"
fi

echo "-------------------"
echo "FINAL PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

# --- R5.1 deep-review F2: a stale legacy ROOT-level generated page is removed
# by the capture run (slug collision with wiki/state/ would be a permanent
# duplicate_slug validate error with no autofix). User-authored root files with
# the same name but no attribution line are left alone.
LEGACY="$KNOWLEDGE_DIR/wiki/cost-routing-patterns.md"
printf '# Cost-Routing Patterns\n\n> Auto-generated by `cost-router-capture.sh`. old copy\n' > "$LEGACY"
COST_ROUTER_EVENTS="$EVENTS" BRAIN_DIR="$BRAIN_DIR" SB_KNOWLEDGE_DIR="$KNOWLEDGE_DIR" bash "$SCRIPT" >/dev/null 2>&1
if [ ! -f "$LEGACY" ]; then
  pass "(f) stale legacy root page removed by capture"
else
  fail "(f) stale legacy root page survived (duplicate_slug landmine)"
fi
printf '# My own notes, same filename\n' > "$LEGACY"
COST_ROUTER_EVENTS="$EVENTS" BRAIN_DIR="$BRAIN_DIR" SB_KNOWLEDGE_DIR="$KNOWLEDGE_DIR" bash "$SCRIPT" >/dev/null 2>&1
if [ -f "$LEGACY" ]; then
  pass "(f) user-authored root file with same name preserved"
else
  fail "(f) capture deleted a NON-generated user file"
fi

# --- (g) 0.29.4: zero-escalation happy path — the `grep -c … || echo 0` branch ---
# grep -c prints "0" AND exits 1 on no-match, so `|| echo 0` USED to fire too, making
# _ESCALATED/_OK_COUNT/_COMMITTED the two-line string "0\n0" → the escalation bullet split
# across two lines with a dangling orphan count. Every prior fixture carried ≥1 escalation,
# so this branch was never exercised. Feed all-false events and assert the bullet renders
# the count on ONE line (the existing line-122 oracle is line-based, so a split fails it).
cat > "$EVENTS" <<'EOF'
{"ts":"2026-06-09T12:00:00Z","task":"a","tier":"DO","models":["sonnet"],"units":1,"escalated":false,"outcome":"ok","committed":false}
{"ts":"2026-06-09T12:05:00Z","task":"b","tier":"DO","models":["sonnet"],"units":1,"escalated":false,"outcome":"ok","committed":false}
EOF
COST_ROUTER_EVENTS="$EVENTS" BRAIN_DIR="$BRAIN_DIR" SB_KNOWLEDGE_DIR="$KNOWLEDGE_DIR" bash "$SCRIPT" >/dev/null 2>&1
if grep -qE '^- \*\*Total escalated to Opus:\*\* 0 of 2 ' "$PATTERNS_PAGE"; then
  pass "(g) zero-escalation bullet renders the count on ONE line (no 0\\n0 split)"
else
  fail "(g) zero-escalation bullet split — grep -c '||' echo 0 double-emit: $(grep -A1 'Total escalated' "$PATTERNS_PAGE" | tr '\n' '/')"
fi
# orphan-line guard: no line may be a bare 'N of M' count with no descriptive prefix.
if grep -qE '^[0-9]+ of [0-9]+' "$PATTERNS_PAGE"; then
  fail "(g) orphan count line present — a bullet was split by an embedded newline"
else
  pass "(g) no orphan count lines (every count stays attached to its bullet)"
fi

echo "-------------------"
echo "FINAL2 PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
