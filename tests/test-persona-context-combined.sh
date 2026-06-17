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

# --- E: PRESENT-but-broken combined bundle falls back to the single CLIs ------
# (rc-gated, not just [ -f ] — a truncated cache write must not silently lose
# both hints while the single CLIs still work; R6b review finding.)
D="$SANDBOX/ptree"; mkdir -p "$D/mcp/dist/tools"
cp -r "$REPO_ROOT/scripts" "$D/scripts"
cp "$REPO_ROOT/kb-schema.json" "$D/kb-schema.json" 2>/dev/null || true
echo 'this is not javascript' > "$D/mcp/dist/tools/context-serve-cli.bundle.js"
cp "$REPO_ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js" \
   "$REPO_ROOT/mcp/dist/tools/episodic-search-cli.bundle.js" "$D/mcp/dist/tools/"
BRAIN_E="$SANDBOX/brain-e"; mkdir -p "$BRAIN_E"
printf '# Persona\n\n## Identity\n- combined-fallback-test\n' > "$BRAIN_E/persona-card.md"
E_OUT=$(printf '{"prompt":"tell me about the tunnel alpha page details","session_id":"e-sess"}' \
  | CLAUDE_PLUGIN_ROOT="$D" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KD" \
    KNOWLEDGE_DIR="$KD" BRAIN_DIR="$BRAIN_E" SECOND_BRAIN_DISABLE_EMBEDDINGS=1 \
    bash "$D/scripts/persona-context.sh" 2>/dev/null || true)
printf '%s\n' "$E_OUT" | grep -q 'tunnel-alpha' \
  || fail "E: broken combined bundle lost the wiki hint (no fallback to single CLIs): $E_OUT"
pass "E: broken combined bundle falls back to the two-CLI path"

# --- F: dismissal-aware backoff — >= N recent dismissals suppress the ambient injection -------
# ORACLE: persona-context.sh output. With >= SB_PERSONA_DISMISS_MAX (default 3) dismissals dated
# inside the window, the gate must exit 0 with NO output even for an action prompt that would
# otherwise surface the tunnel-alpha wiki hit.
TODAY=$(date -u +%Y-%m-%d)
BRAIN_F="$SANDBOX/brain-f"; mkdir -p "$BRAIN_F"
for i in 1 2 3; do printf '{"at":"%sT12:00:0%dZ","reason":"noise"}\n' "$TODAY" "$i"; done > "$BRAIN_F/.persona-dismissals.jsonl"
F_OUT=$(printf '{"prompt":"implement the tunnel alpha page feature now","session_id":"f-sess"}' \
  | CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KD" KNOWLEDGE_DIR="$KD" BRAIN_DIR="$BRAIN_F" \
    SECOND_BRAIN_DISABLE_EMBEDDINGS=1 bash "$PC" 2>/dev/null || true)
[ -z "$F_OUT" ] || fail "F: >=3 recent dismissals must suppress the ambient injection, got: $F_OUT"
pass "F: dismissal-aware backoff suppresses injection after >= SB_PERSONA_DISMISS_MAX dismissals"

# --- G: below the dismissal threshold → injection still fires (positive control) --------------
BRAIN_G="$SANDBOX/brain-g"; mkdir -p "$BRAIN_G"
printf '{"at":"%sT12:00:00Z","reason":"noise"}\n' "$TODAY" > "$BRAIN_G/.persona-dismissals.jsonl"  # 1 < 3
G_OUT=$(printf '{"prompt":"implement the tunnel alpha page feature now","session_id":"g-sess"}' \
  | CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KD" KNOWLEDGE_DIR="$KD" BRAIN_DIR="$BRAIN_G" \
    SECOND_BRAIN_DISABLE_EMBEDDINGS=1 bash "$PC" 2>/dev/null || true)
printf '%s\n' "$G_OUT" | grep -q 'tunnel-alpha' \
  || fail "G: 1 dismissal (< threshold) must NOT suppress injection, got: $G_OUT"
pass "G: below the dismissal threshold the injection still fires"

echo "ALL PASS"
