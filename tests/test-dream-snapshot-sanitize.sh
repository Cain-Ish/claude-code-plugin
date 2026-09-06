#!/usr/bin/env bash
# P6b: dream-snapshot must stage a SANITIZED copy of each transcript (invisible/Tags-block
# smuggling chars stripped) before the dream-runner agent reads it — AND must never mutate the
# source transcript (POSIX staging previously symlinked the original; sanitizing in place would
# have corrupted it).
#
# ORACLE: raw bytes. The staged copy must NOT contain the Tags-block / ZWSP bytes; the ORIGINAL
# transcript MUST still contain them (proves source-untouched). The visible text must survive.
set -u
unset CLAUDECODE ANTHROPIC_API_KEY SB_EXTRACTOR_LOCAL_URL 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SNAP="$REPO_ROOT/scripts/dream-snapshot.sh"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# The bundled sanitizer must exist for the real (non-degraded) path to run.
[ -f "$REPO_ROOT/mcp/dist/tools/sanitize-cli.bundle.js" ] || fail "sanitize-cli bundle missing — run npm run build"

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
export BRAIN_DIR="$SANDBOX/brain"
export KNOWLEDGE_DIR="$SANDBOX/knowledge"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"
mkdir -p "$BRAIN_DIR/transcripts" "$KNOWLEDGE_DIR/wiki/entities"
printf -- '---\ntitle: x\ntype: entities\nrelated: []\n---\n\n# x\n\nbody\n' > "$KNOWLEDGE_DIR/wiki/entities/x.md"

# Smuggling bytes: U+E0041 TAG LATIN A (F3 A0 81 81) + U+200B ZWSP (E2 80 8B).
TAG=$(printf '\363\240\201\201'); ZWSP=$(printf '\342\200\213')
ORIG="$BRAIN_DIR/transcripts/sess1_alpha_2026-06-28.txt"
printf 'USER:\nplease rate%slimit%s api\n' "$TAG" "$ZWSP" > "$ORIG"

CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$SNAP" --max-count 5 >/dev/null 2>&1 || true

STAGED=$(find "$BRAIN_DIR/dreams" -path '*/transcripts/sess1_alpha_2026-06-28.txt' 2>/dev/null | head -1)
[ -n "$STAGED" ] || fail "snapshot did not produce a staged transcript copy"

# (a) staged copy is CLEAN
if LC_ALL=C grep -qF "$TAG" "$STAGED" || LC_ALL=C grep -qF "$ZWSP" "$STAGED"; then
  fail "staged transcript still contains invisible/Tags-block chars"
fi
pass "staged transcript is sanitized (no Tags-block / ZWSP bytes)"

# (b) visible text survived
LC_ALL=C grep -qF 'ratelimit api' "$STAGED" || fail "visible text was corrupted by sanitization (expected 'ratelimit api')"
pass "visible text preserved"

# (c) SOURCE transcript is untouched (the symlink-corruption guard)
if LC_ALL=C grep -qF "$TAG" "$ORIG" && LC_ALL=C grep -qF "$ZWSP" "$ORIG"; then
  pass "original transcript left untouched (source not mutated)"
else
  fail "ORIGINAL transcript was modified — sanitizer wrote through to the source"
fi

# --- (d) security review follow-up: `--slug` is matched as a FIXED STRING per
# requested slug, not built into one regex alternation (`_(${ALT})_`). A slug
# of '.*' must select NOTHING, not act as a wildcard over every transcript.
rm -rf "$BRAIN_DIR/dreams"   # the sanitize dream above is still "pending" — clear it first
DID=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$SNAP" --slug '.*' --max-count 5 2>/dev/null)
[ -n "$DID" ] || fail "review follow-up: dream-snapshot.sh --slug '.*' produced no dream id"
TC=$(jq -r '.inputs.transcript_count' "$BRAIN_DIR/dreams/$DID/status.json" 2>/dev/null)
[ "$TC" = "0" ] || fail "review follow-up: --slug '.*' matched $TC transcript(s) as a wildcard — must select none (fixed-string match only)"
pass "review follow-up: --slug '.*' is a fixed-string literal (selects zero transcripts, not a wildcard)"

echo "ALL PASS"
