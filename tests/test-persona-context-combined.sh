#!/usr/bin/env bash
# R6b (HOOK-7): the per-prompt UserPromptSubmit hook paid TWO node cold-starts
# (~0.5-1s each on a Pi 5) — knowledge-search-cli then episodic-search-cli.
# The combined context-serve-cli answers both in ONE process (one boot, one
# engine load); persona-context.sh prefers it and falls back to the two-CLI
# path when the bundle is absent (stale plugin cache safety).
set -u
unset CLAUDECODE ANTHROPIC_API_KEY SB_EXTRACTOR_LOCAL_URL 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }
SEP='--8<--SB-EPISODIC--8<--'

PC="$REPO_ROOT/scripts/persona-context.sh"
COMBINED="$REPO_ROOT/mcp/dist/tools/context-serve-cli.bundle.js"

# --- A: static wiring ---------------------------------------------------------
grep -q 'context-serve-cli.bundle.js' "$PC" \
  || fail "A: persona-context.sh does not reference the combined CLI"
grep -q 'knowledge-search-cli.bundle.js' "$PC" \
  || fail "A: persona-context.sh lost the knowledge-search fallback path"
grep -q 'episodic-search-cli.bundle.js' "$PC" \
  || fail "A: persona-context.sh lost the episodic-search fallback path"
grep -q 'context-serve-cli' "$REPO_ROOT/mcp/package.json" \
  || fail "A: mcp/package.json bundle script lacks the context-serve-cli entry"
pass "A: combined CLI wired with two-CLI fallback"

# --- B: runtime — wiki-section parity with knowledge-search-cli --------------
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 0; }
[ -f "$COMBINED" ] || fail "B: dist/tools/context-serve-cli.bundle.js not built (npm run bundle)"

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
KD="$SANDBOX/kd"; BRAIN="$SANDBOX/brain"
mkdir -p "$KD/wiki/concepts" "$BRAIN"
cat > "$KD/wiki/concepts/tunnel-alpha.md" <<'EOF'
---
title: "tunnel alpha page"
description: "about tunnels"
type: concepts
---

# tunnel alpha page

tunnel content here for matching tunnel tunnel
EOF
printf '{"version":1,"exchanges":[]}\n' > "$BRAIN/episodic-index.json"

RUNENV="KNOWLEDGE_DIR=$KD BRAIN_DIR=$BRAIN SB_BRAIN_DIR=$BRAIN KNOWLEDGE_MIN_SCORE=0 SECOND_BRAIN_DISABLE_EMBEDDINGS=1"
COMBINED_OUT=$(env $RUNENV node "$COMBINED" "tunnel alpha" 2>/dev/null || true)
SINGLE_OUT=$(env $RUNENV node "$REPO_ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js" "tunnel alpha" 2>/dev/null || true)

printf '%s\n' "$COMBINED_OUT" | grep -q '\[\[tunnel-alpha\]\]' \
  || fail "B: combined CLI missing the wiki hit ([[tunnel-alpha]]): $COMBINED_OUT"
WIKI_PART=$(printf '%s\n' "$COMBINED_OUT" | awk -v s="$SEP" '$0==s{exit}{print}')
[ "$WIKI_PART" = "$SINGLE_OUT" ] \
  || fail "B: wiki section diverges from knowledge-search-cli output
combined: $WIKI_PART
single:   $SINGLE_OUT"
pass "B: wiki section is byte-identical to knowledge-search-cli"

# --- C: separator contract ----------------------------------------------------
printf '%s\n' "$COMBINED_OUT" | grep -qx -- "$SEP" \
  || fail "C: separator line '$SEP' missing when a section is non-empty"
EPI_PART=$(printf '%s\n' "$COMBINED_OUT" | awk -v s="$SEP" 'f{print} $0==s{f=1}')
[ -z "$EPI_PART" ] || fail "C: episodic section should be empty on an empty index, got: $EPI_PART"
pass "C: separator present; empty episodic section after it"

# --- D: both-empty → silent exit 0 -------------------------------------------
EMPTY_OUT=$(env $RUNENV node "$COMBINED" "zzqx9 nonexistent gibberish" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] || fail "D: combined CLI exited $rc on no-hit keywords"
[ -z "$EMPTY_OUT" ] || fail "D: expected no output when both sections empty, got: $EMPTY_OUT"
pass "D: silent exit 0 when nothing surfaced"

echo "ALL PASS"
